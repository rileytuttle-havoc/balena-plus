<#
.SYNOPSIS
    Install balena-plus for Windows PowerShell.

.DESCRIPTION
    The Windows counterpart to install.sh. A wrapper around the balena CLI
    that lets you say 'balena ssh foo-device' instead of pasting a UUID,
    picks a device out of a fleet, and adds tunnel/logs/ps helpers.

        irm https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1 | iex

    Asks before it does anything. Safe to re-run: it upgrades an existing
    install rather than duplicating it.

    To pass switches through the one-liner, build a scriptblock instead --
    'iex' cannot forward arguments:

        & ([scriptblock]::Create((irm <url>))) -Yes

.PARAMETER Yes
    Answer yes to every prompt (non-interactive).

.PARAMETER SkipProfile
    Do not offer to add the Import-Module line to your PowerShell profile.

.PARAMETER Uninstall
    Remove the module and the profile line, and stop.
#>
[CmdletBinding()]
param(
    [switch] $Yes,
    [switch] $SkipProfile,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$RepoRaw    = 'https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main'
$RepoApi    = 'https://api.github.com/repos/rileytuttle-havoc/balena-plus/commits/main'
$CliDocsUrl = 'https://github.com/balena-io/balena-cli/blob/master/INSTALL.md'
$LocalAppData = $env:LOCALAPPDATA
if (-not $LocalAppData) { $LocalAppData = [Environment]::GetFolderPath('LocalApplicationData') }
if (-not $LocalAppData) { $LocalAppData = [System.IO.Path]::GetTempPath() }
$InstallDir = Join-Path (Join-Path $LocalAppData 'balena-plus') 'BalenaPlus'
$Marker     = '# balena-plus'

$script:AssumeYes = [bool]$Yes

# ------------------------------------------------------------------- plumbing

function Write-Heading { param([string] $Text) Write-Host ''; Write-Host $Text -ForegroundColor White }
function Write-Info    { param([string] $Text) Write-Host $Text }
function Write-Note    { param([string] $Text) Write-Host $Text -ForegroundColor DarkGray }
function Write-Warn    { param([string] $Text) Write-Host "Warning: $Text" -ForegroundColor Yellow }

function Confirm-Step {
    param([string] $Question)
    if ($script:AssumeYes) { return $true }
    $reply = Read-Host "$Question [y / N / Y = yes to all]"
    if ($reply -ceq 'Y') { $script:AssumeYes = $true; return $true }
    if ($reply -eq 'y' -or $reply -eq 'yes') { return $true }
    return $false
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 on older builds still negotiates TLS 1.0, which
    # GitHub refuses outright.
    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::SecurityProtocol =
            [System.Net.ServicePointManager]::SecurityProtocol -bor $tls12
    } catch { Write-Note 'Could not raise TLS to 1.2; downloads may fail.' }
}

function Test-HaveCommand {
    param([string] $Name)
    return [bool](Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

# ----------------------------------------------------------------- uninstall

function Invoke-Uninstall {
    Write-Heading 'Uninstalling balena-plus'
    $parent = Split-Path $InstallDir -Parent
    if (Test-Path -LiteralPath $parent) {
        if (Confirm-Step "Remove $parent (module and caches)?") {
            Remove-Item -LiteralPath $parent -Recurse -Force
            Write-Info "  removed $parent"
        }
    } else {
        Write-Note "  nothing installed at $parent"
    }
    if ((Test-Path -LiteralPath $PROFILE) -and (Select-String -LiteralPath $PROFILE -SimpleMatch $Marker -Quiet)) {
        if (Confirm-Step "Remove the balena-plus lines from $PROFILE ?") {
            $kept = Get-Content -LiteralPath $PROFILE | Where-Object {
                $_ -notmatch [regex]::Escape($Marker) -and $_ -notmatch 'BalenaPlus\.psd1'
            }
            Set-Content -LiteralPath $PROFILE -Value $kept
            Write-Info "  cleaned $PROFILE"
        }
    }
    Write-Info ''
    Write-Info 'Done. Open a new PowerShell window for it to take effect.'
}

# --------------------------------------------------------------------- checks

function Test-Prerequisite {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "balena-plus needs Windows PowerShell 5.1 or newer; this is $($PSVersionTable.PSVersion)."
    }

    Write-Info ''
    if (Test-HaveCommand 'balena') {
        $where = (Get-Command balena -CommandType Application | Select-Object -First 1).Source
        Write-Info "Found balena-cli at $where -- this will use it as-is,"
        Write-Info 'and will not install a second copy.'
        return
    }

    Write-Warn 'No balena-cli found on your PATH.'
    Write-Info ''
    Write-Info 'balena-plus wraps your own balena CLI rather than shipping one, so'
    Write-Info 'that installing it does not duplicate a CLI you already have. That'
    Write-Info 'also means it needs one to exist.'
    Write-Info ''

    if (Test-HaveCommand 'npm') {
        Write-Info 'Found npm. balena-cli can be installed with:'
        Write-Note '  npm install -g balena-cli'
        if (Confirm-Step 'Install balena-cli via npm now?') {
            npm install -g balena-cli
            if ($LASTEXITCODE -ne 0) { Write-Warn 'npm install failed; carrying on without it.' }
        }
    } else {
        Write-Info 'No npm either. The standalone installer is at:'
        Write-Note "  $CliDocsUrl"
        # Only worth offering to a human: under -Yes this is answered for us,
        # and opening a browser is not something a non-interactive run should
        # do. Wrapped either way -- with no registered URL handler (Server
        # Core, an SSH session) Start-Process throws, and $ErrorActionPreference
        # is 'Stop', so an unguarded call would abort the whole install over a
        # failure to show a web page.
        if (-not $script:AssumeYes -and (Confirm-Step 'Open that page in your browser?')) {
            try { Start-Process $CliDocsUrl } catch { Write-Note '  could not open a browser; the URL is above.' }
        }
        Write-Info ''
        Write-Info 'balena-plus will install fine without it, but will not run until'
        Write-Info 'a balena CLI is on your PATH.'
    }
}

function Confirm-ExecutionPolicy {
    # The module is a .psm1 on disk, so unlike this script (which 'iex' runs
    # from memory) it is subject to execution policy.
    $effective = Get-ExecutionPolicy
    if ($effective -ne 'Restricted' -and $effective -ne 'AllSigned') { return }

    Write-Heading 'Execution policy'
    Write-Info "Your execution policy is '$effective', which blocks loading local"
    Write-Info 'modules, so balena-plus would install but refuse to import.'
    Write-Info ''
    Write-Note '  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    Write-Info ''
    Write-Info 'That affects your account only, not the machine.'
    if (Confirm-Step 'Set it?') {
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
        Write-Info '  done'
    } else {
        Write-Warn 'Leaving it; "Import-Module BalenaPlus" will fail until it changes.'
    }
}

# ---------------------------------------------------------------- the install

function Get-SourceFile {
    # Prefer a local checkout when the installer is run from one, so the repo
    # can be tested without pushing. Falls back to downloading.
    param([string] $Name)

    if ($PSScriptRoot) {
        $local = Join-Path (Join-Path $PSScriptRoot 'BalenaPlus') $Name
        if (Test-Path -LiteralPath $local) {
            return [IO.File]::ReadAllText($local)
        }
    }
    $url = "$RepoRaw/windows/BalenaPlus/$Name"
    Write-Note "  fetching $Name"
    return (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
}

function Get-UpstreamRev {
    # Stamped into rev.txt so the module's once-a-day update check knows what
    # it is running. Absent or unknown simply disables that check.
    if ($PSScriptRoot) {
        try {
            $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
            if ($git) {
                $sha = (& $git.Source -C $PSScriptRoot rev-parse HEAD 2>$null)
                if ($LASTEXITCODE -eq 0 -and $sha) { return $sha.Trim() }
            }
        } catch { }
    }
    try {
        $headers = @{ 'User-Agent' = 'balena-plus-installer'; 'Accept' = 'application/vnd.github.sha' }
        return (Invoke-RestMethod -Uri $RepoApi -Headers $headers -TimeoutSec 10).Trim()
    } catch {
        return 'unknown'
    }
}

function Install-BalenaPlusModule {
    Write-Heading 'Installing the module'
    Write-Info "  to $InstallDir"
    if (-not (Confirm-Step 'Install there?')) {
        Write-Info 'Skipped.'
        return $false
    }

    $psm1 = Get-SourceFile 'BalenaPlus.psm1'
    $psd1 = Get-SourceFile 'BalenaPlus.psd1'
    $rev = Get-UpstreamRev

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    # UTF8 without BOM would be nicer, but 5.1's Set-Content cannot write it
    # and a BOM is harmless for a module.
    Set-Content -LiteralPath (Join-Path $InstallDir 'BalenaPlus.psm1') -Value $psm1 -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $InstallDir 'BalenaPlus.psd1') -Value $psd1 -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $InstallDir 'rev.txt') -Value $rev -Encoding UTF8

    # Strip any mark-of-the-web so RemoteSigned does not refuse the module.
    Get-ChildItem -LiteralPath $InstallDir -File | ForEach-Object {
        try { Unblock-File -LiteralPath $_.FullName } catch { }
    }

    Write-Info "  installed (revision $($rev.Substring(0, [Math]::Min(7, $rev.Length))))"
    return $true
}

function Add-ProfileLine {
    $importLine = "Import-Module '$(Join-Path $InstallDir 'BalenaPlus.psd1')'"

    Write-Heading 'Shell integration'
    Write-Info 'This line makes "balena" the wrapper in every new session, and'
    Write-Info 'turns on tab completion for device and fleet names:'
    Write-Info ''
    Write-Note "  $importLine"
    Write-Info ''

    if ($SkipProfile) {
        Write-Info "Add it to your profile yourself: $PROFILE"
        return
    }

    if ((Test-Path -LiteralPath $PROFILE) -and (Select-String -LiteralPath $PROFILE -SimpleMatch $Marker -Quiet)) {
        Write-Info "Your profile already loads balena-plus; leaving $PROFILE alone."
        return
    }

    if (-not (Confirm-Step "Add it to $PROFILE ?")) {
        Write-Info 'Not added. Paste the line above into your profile when you want it.'
        return
    }

    $dir = Split-Path $PROFILE -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -LiteralPath $PROFILE -Value @('', $Marker, $importLine)
    Write-Info "  added to $PROFILE"

    # $PROFILE is per-edition: a line added from Windows PowerShell does
    # nothing in PowerShell 7, and the other way round. Worth saying out
    # loud, because Windows Terminal makes running both of them normal.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $other = 'PowerShell 7 (pwsh)'
    } else {
        $other = 'Windows PowerShell 5.1'
    }
    Write-Note "  that is this edition's profile. If you also use $other,"
    Write-Note '  add the same line to its $PROFILE.'
}

# ------------------------------------------------------------------------ run

Enable-Tls12

if ($Uninstall) {
    Invoke-Uninstall
    return
}

Write-Heading 'balena-plus'
Write-Info 'A wrapper around the balena CLI. It lets you say "balena ssh foo-device"'
Write-Info 'instead of pasting a UUID, picks a device out of a fleet, and adds'
Write-Info 'tunnel/logs/ps helpers. The balena CLI itself does the real work.'

Test-Prerequisite
Confirm-ExecutionPolicy

if (Install-BalenaPlusModule) {
    Add-ProfileLine

    Write-Heading 'Done'
    Write-Info 'Open a new PowerShell window, then try:'
    Write-Note '  balena devices'
    Write-Note '  balena ssh <device-name>'
    Write-Info ''
    Write-Info 'The raw CLI is at "balena-raw". "balena help" explains the rest,'
    Write-Info 'and "Update-BalenaPlus" re-runs this installer later on.'
}
