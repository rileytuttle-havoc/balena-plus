#Requires -Version 5.1
<#
    BalenaPlus -- the Windows PowerShell port of balena-plus.sh.

    Same idea as the bash original: a thin wrapper around the balena CLI that
    resolves device names, picks a device out of a fleet, and adds a few
    convenience commands. The raw balena command is printed before each run,
    so this teaches the CLI rather than hiding it.

    The balena CLI itself is deliberately NOT shipped here. The wrapper uses
    whatever 'balena' is already on your PATH, so installing this does not
    land a second ~630MB copy on a machine that has one.

    Differences from the bash version, and why:

      * No python3 dependency -- ConvertFrom-Json is built in.
      * 'devices' emits objects, not text, so you can pipe it:
            balena devices | Where-Object Status -eq online
      * No 'shell-init': on Windows the profile imports this module instead,
        and completion is registered here by Register-ArgumentCompleter.
      * No '\balena' escape (PowerShell has no such syntax) -- use the
        exported 'balena-raw' instead.
      * Nothing ever calls exit. This runs as a function inside the user's
        shell, so exit would kill their session; errors throw and the public
        entry point catches them and sets $LASTEXITCODE.

    Written to run on Windows PowerShell 5.1, which is what ships with
    Windows 10/11. That rules out ternaries, ??, && and -AsHashtable.
#>

# ---------------------------------------------------------------- module state

$script:UpstreamUrl = 'https://github.com/rileytuttle-havoc/balena-plus'
$script:InstallUrl  = 'https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1'
$script:ApiUrl      = 'https://api.github.com/repos/rileytuttle-havoc/balena-plus/commits/main'

# install.ps1 drops a rev.txt beside this file. Running straight from a
# checkout leaves it absent, which disables the update check -- the same
# "unknown" fallback the nix build uses.
$script:SelfRev = 'unknown'
$script:RevFile = Join-Path $PSScriptRoot 'rev.txt'
if (Test-Path -LiteralPath $script:RevFile) {
    $script:SelfRev = (Get-Content -LiteralPath $script:RevFile -TotalCount 1).Trim()
}

function Get-PlusCacheRoot {
    # %LOCALAPPDATA% on Windows, which is the only case that really matters.
    # The fallbacks are for importing this under PowerShell 7 on Linux or
    # macOS, and for service accounts where the variable is not populated:
    # a null cache path would otherwise throw on every single command.
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not $base) { $base = $env:XDG_CACHE_HOME }
    if (-not $base -and $env:HOME) { $base = Join-Path $env:HOME '.cache' }
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'balena-plus')
}

$script:CacheDir      = Get-PlusCacheRoot
$script:NamesCache    = Join-Path $script:CacheDir 'device-names.txt'
$script:CommandsCache = Join-Path $script:CacheDir 'balena-commands.txt'
$script:UpdateStamp   = Join-Path $script:CacheDir 'update-check'

# Resolved once per session; Get-PlusCli re-probes if the CLI disappears.
$script:CliPath = $null
# Device list memo, valid only for the duration of one top-level invocation.
$script:DeviceList = $null

$script:PlusCommands = @('ssh', 'tunnel', 'logs', 'ps', 'uuid', 'devices', 'help')

# Used only when 'balena help' cannot be parsed. Approximates balena-cli v18+.
$script:FallbackBalenaCommands = @(
    'api-key', 'block', 'build', 'config', 'deploy', 'device', 'devices', 'env',
    'fleet', 'internal', 'join', 'leave', 'local', 'login', 'logout', 'logs',
    'note', 'orgs', 'os', 'preload', 'push', 'release', 'scan', 'settings',
    'ssh', 'support', 'tag', 'tunnel', 'util', 'version', 'whoami'
)

# ---------------------------------------------------------------- small helpers

function Write-PlusShow {
    # The teaching line: the raw balena command you could have typed. Goes to
    # the host, not stdout, so 'balena uuid foo' stays pipeable.
    param([string] $Text)
    if ($script:Verbose) {
        Write-Host "+ $Text" -ForegroundColor DarkGray
    }
}

function Format-PlusArg {
    # Quote an argument the way you would type it at a PowerShell prompt.
    # Display only -- nothing is executed through a shell.
    param([string] $Value)
    if ($null -eq $Value -or $Value -eq '') { return "''" }
    if ($Value -match '^[A-Za-z0-9_@%+=:,./\\-]+$') { return $Value }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-PlusArgs {
    param([string[]] $Values)
    if (-not $Values -or $Values.Count -eq 0) { return '' }
    return (($Values | ForEach-Object { Format-PlusArg $_ }) -join ' ')
}

function Format-PlusShArg {
    # POSIX single-quoting, for text that will be read by the DEVICE's shell.
    # The device host is Linux whatever the client is, so this stays sh syntax.
    param([string] $Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Get-PlusCli {
    if ($script:CliPath -and (Test-Path -LiteralPath $script:CliPath)) {
        return $script:CliPath
    }
    $cmd = Get-Command -Name 'balena' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $cmd) {
        # No leading indentation on the continuation lines, deliberately.
        # This reaches the user through Write-Error, and PowerShell 7's
        # default error view joins a multi-line message back into one
        # paragraph -- where an indent survives as a double space in the
        # middle of a sentence. Flush left reads correctly in both that view
        # and the plain multi-line one Windows PowerShell 5.1 uses.
        throw @'
balena CLI not found in PATH.
balena-plus wraps your own balena-cli rather than shipping one, so that
installing it does not duplicate a CLI you already have. Install it with
'npm install -g balena-cli', or from
https://github.com/balena-io/balena-cli/blob/master/INSTALL.md
'@
    }
    $script:CliPath = $cmd.Source
    return $script:CliPath
}

function Invoke-PlusCliJson {
    # Run balena and parse --json output. Forces UTF-8 for the capture so that
    # non-ASCII device names survive; 5.1 otherwise decodes native output with
    # the console's OEM codepage.
    param([Parameter(Mandatory = $true)][string[]] $CliArgs)

    $cli = Get-PlusCli
    $previous = $null
    try {
        try {
            $previous = [Console]::OutputEncoding
            [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        } catch {
            $previous = $null   # some hosts refuse; carry on undecorated
        }
        $out = & $cli @CliArgs 2>$null
    } finally {
        if ($previous) {
            try { [Console]::OutputEncoding = $previous } catch { }
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "balena $($CliArgs -join ' ') failed (exit $LASTEXITCODE)"
    }
    $text = ($out -join "`n").Trim()
    if (-not $text) { return @() }
    try {
        return @(ConvertFrom-Json $text)
    } catch {
        throw "could not parse JSON from 'balena $($CliArgs -join ' ')': $($_.Exception.Message)"
    }
}

function Test-PlusLogin {
    # Mirrors ensure_login. Get-PlusCli throws its own message if there is no CLI.
    $cli = Get-PlusCli
    & $cli whoami *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Not logged in to balena, starting web login...' -ForegroundColor Yellow
        Write-PlusShow 'balena login --web'
        & $cli login --web
        if ($LASTEXITCODE -ne 0) { throw 'balena login failed' }
    }
}

# ------------------------------------------------------- devices and resolution

function Get-PlusDeviceList {
    if ($null -eq $script:DeviceList) {
        $script:DeviceList = @(Invoke-PlusCliJson -CliArgs @('device', 'list', '--json'))
        Write-PlusNamesCache -Devices $script:DeviceList
    }
    return $script:DeviceList
}

function Write-PlusNamesCache {
    # Device names for tab completion, one per line. Refreshed whenever the
    # device list is fetched, so ordinary use keeps it warm.
    param([object[]] $Devices)
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        }
        $names = @($Devices | ForEach-Object { $_.device_name } | Where-Object { $_ })
        $tmp = "$script:NamesCache.tmp"
        Set-Content -LiteralPath $tmp -Value $names -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:NamesCache -Force
    } catch {
        # A cold completion cache is not worth failing a command over.
    }
}

function Get-PlusFleetName {
    # The fleet field has worn several shapes across balena-cli versions:
    # a slug string, an array, or an object with app_name/slug.
    param([object] $Device)
    $fleet = $Device.fleet
    if (-not $fleet) { $fleet = $Device.belongs_to__application }
    if (-not $fleet) { return '' }
    if ($fleet -is [array]) {
        if ($fleet.Count -eq 0) { return '' }
        $fleet = $fleet[0]
    }
    if ($fleet -is [string]) { return $fleet }
    if ($fleet.app_name) { return [string]$fleet.app_name }
    if ($fleet.slug) { return [string]$fleet.slug }
    return ''
}

function Find-PlusDevice {
    # Match by name/UUID prefix ('exact') or name substring ('substring').
    # Returns a UUID, or $null when nothing matched. Throws when ambiguous.
    param(
        [ValidateSet('exact', 'substring')][string] $Mode,
        [string] $Query
    )
    $devices = Get-PlusDeviceList
    $matched = @()

    if ($Mode -eq 'exact') {
        $matched = @($devices | Where-Object { $_.device_name -ceq $Query })
        if ($matched.Count -eq 0) {
            $lower = $Query.ToLowerInvariant()
            $matched = @($devices | Where-Object { $_.uuid -and $_.uuid.StartsWith($lower) })
        }
    } else {
        $lower = $Query.ToLowerInvariant()
        $matched = @($devices | Where-Object {
            $_.device_name -and $_.device_name.ToLowerInvariant().Contains($lower)
        })
    }

    if ($matched.Count -eq 1) { return $matched[0].uuid }
    if ($matched.Count -gt 1) {
        $names = (($matched | ForEach-Object { $_.device_name } | Sort-Object) -join ', ')
        throw "'$Query' matches multiple devices: $names"
    }
    return $null
}

function Find-PlusFleet {
    # Match a fleet by name or slug, case-insensitively. Returns the slug, or
    # $null. A failure to list fleets is treated as "no match" so that a
    # permissions quirk degrades to the substring search rather than hard-failing.
    param([string] $Query)
    $lower = $Query.ToLowerInvariant()
    try {
        $fleets = @(Invoke-PlusCliJson -CliArgs @('fleet', 'list', '--json'))
    } catch {
        return $null
    }
    foreach ($f in $fleets) {
        $name = ''
        $slug = ''
        if ($f.app_name) { $name = ([string]$f.app_name).ToLowerInvariant() }
        if ($f.slug) { $slug = ([string]$f.slug).ToLowerInvariant() }
        if ($lower -eq $name -or $lower -eq $slug) {
            if ($f.slug) { return [string]$f.slug }
            return [string]$f.app_name
        }
    }
    return $null
}

function Select-PlusFleetDevice {
    # Interactively pick a device from a fleet, online ones first. fzf if it is
    # installed, otherwise a numbered menu. BALENA_PLUS_PICKER forces one of
    # 'fzf', 'grid' (Out-GridView, a GUI popup) or 'select' (the menu).
    param([string] $Fleet)

    $devices = @(Invoke-PlusCliJson -CliArgs @('device', 'list', '--fleet', $Fleet, '--json'))
    if ($devices.Count -eq 0) { throw "fleet '$Fleet' has no devices" }

    $rows = @($devices |
        Sort-Object @{ Expression = { -not $_.is_online } }, @{ Expression = { $_.device_name } } |
        ForEach-Object {
            $status = 'offline'
            if ($_.is_online) { $status = 'online' }
            [PSCustomObject]@{
                Uuid  = $_.uuid
                Label = ('{0,-24} {1}  {2}' -f $_.device_name, $_.uuid.Substring(0, 7), $status)
            }
        })

    if ($rows.Count -eq 1) {
        Write-Host "Fleet '$Fleet' has one device: $($rows[0].Label)" -ForegroundColor DarkGray
        return $rows[0].Uuid
    }

    $picker = $env:BALENA_PLUS_PICKER
    $haveFzf = [bool](Get-Command -Name 'fzf' -CommandType Application -ErrorAction SilentlyContinue)

    if ($picker -ne 'select' -and $picker -ne 'grid' -and $haveFzf) {
        # Tab-delimited so fzf can display the label but return the UUID with it.
        $lines = @($rows | ForEach-Object { "$($_.Uuid)`t$($_.Label)" })
        $picked = $lines | fzf --delimiter "`t" --with-nth 2 --no-multi --height 40% --reverse `
            --prompt "$Fleet> " --header 'select a device (type to filter, esc to cancel)'
        if (-not $picked) { throw 'no device selected' }
        return ($picked -split "`t")[0]
    }

    if ($picker -eq 'grid') {
        try {
            $sel = $rows | Out-GridView -Title "Select a device from fleet '$Fleet'" -OutputMode Single
            if (-not $sel) { throw 'no device selected' }
            return $sel.Uuid
        } catch [System.Management.Automation.CommandNotFoundException] {
            # No GUI subsystem (Server Core, SSH session) -- fall through.
            Write-Host 'Out-GridView unavailable here; falling back to a menu.' -ForegroundColor DarkGray
        }
    }

    Write-Host "Select a device from fleet '$Fleet':"
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Write-Host ('  {0,3}) {1}' -f ($i + 1), $rows[$i].Label)
    }
    $answer = Read-Host 'Device #'
    $index = 0
    if (-not [int]::TryParse($answer, [ref]$index) -or $index -lt 1 -or $index -gt $rows.Count) {
        throw 'no device selected'
    }
    return $rows[$index - 1].Uuid
}

function Resolve-PlusUuid {
    # Resolve a device name, UUID or fleet name to a full device UUID.
    # Order: exact device name / UUID prefix, then fleet (interactive), then
    # name substring -- same precedence as the bash version.
    param([string] $Query)

    $uuid = Find-PlusDevice -Mode exact -Query $Query
    if ($uuid) {
        Write-PlusShow "balena device list | Select-String $(Format-PlusArg $Query)   # -> $uuid"
        return $uuid
    }

    $fleet = Find-PlusFleet -Query $Query
    if ($fleet) {
        $uuid = Select-PlusFleetDevice -Fleet $fleet
        Write-PlusShow "balena device list --fleet $(Format-PlusArg $fleet)   # picked -> $uuid"
        return $uuid
    }

    $uuid = Find-PlusDevice -Mode substring -Query $Query
    if ($uuid) {
        Write-PlusShow "balena device list | Select-String $(Format-PlusArg $Query)   # -> $uuid"
        return $uuid
    }

    throw "no device or fleet matching '$Query'"
}

function Invoke-PlusHostExec {
    # Run a shell script on the device host OS, piped over 'balena device ssh'.
    #
    # The trailing 'exit' matters more here than it does in bash. PowerShell
    # appends its own newline (CRLF on Windows) after the piped string, so the
    # device's shell would see a stray carriage return as a final line. Exiting
    # first means that line is never read.
    param([string] $Uuid, [string] $Script)
    $cli = Get-PlusCli
    ($Script + "`nexit`n") | & $cli device ssh $Uuid
}

# ---------------------------------------------------------------- the commands

function Invoke-PlusSsh {
    param([string[]] $Rest)
    if ($Rest.Count -lt 1) { throw 'usage: balena ssh <device> [service]' }
    $uuid = Resolve-PlusUuid -Query $Rest[0]
    $tail = @($Rest | Select-Object -Skip 1)
    Write-PlusShow ("balena device ssh $uuid " + (Format-PlusArgs $tail)).TrimEnd()
    $cli = Get-PlusCli
    & $cli device ssh $uuid @tail
}

function Invoke-PlusTunnel {
    # 'balena device tunnel', but the -p before each port mapping is optional:
    # a bare '8080:3000' (or '8080') gets one added. An explicit -p/--port
    # still works, so anything the raw CLI accepts is accepted here too.
    param([string[]] $Rest)
    if ($Rest.Count -lt 1) { throw 'usage: balena tunnel <device> <remote>[:[localIP:]local] ...' }
    $uuid = Resolve-PlusUuid -Query $Rest[0]
    $tail = @($Rest | Select-Object -Skip 1)
    if ($tail.Count -lt 1) { throw 'usage: balena tunnel <device> <remote>[:[localIP:]local] ...' }

    $args2 = New-Object System.Collections.Generic.List[string]
    $prev = ''
    foreach ($a in $tail) {
        if ($prev -ne '-p' -and $prev -ne '--port' -and $a -match '^[0-9]+(:[^:]*)*$') {
            $args2.Add('-p')
        }
        $args2.Add($a)
        $prev = $a
    }
    $final = $args2.ToArray()
    Write-PlusShow "balena device tunnel $uuid $(Format-PlusArgs $final)"
    $cli = Get-PlusCli
    & $cli device tunnel $uuid @final
}

function Invoke-PlusLogs {
    # Container logs through the device's own balena engine. The container is
    # picked by substring, and it must match exactly one running container.
    param([string[]] $Rest)
    if ($Rest.Count -lt 2) { throw 'usage: balena logs <device> <container> [-f] [-n N] [-t]' }
    $uuid = Resolve-PlusUuid -Query $Rest[0]
    $container = $Rest[1]

    $logArgs = New-Object System.Collections.Generic.List[string]
    $i = 2
    while ($i -lt $Rest.Count) {
        if ($Rest[$i] -eq '-n' -and ($i + 1) -lt $Rest.Count) {
            $logArgs.Add('--tail')
            $logArgs.Add($Rest[$i + 1])
            $i += 2
        } else {
            $logArgs.Add($Rest[$i])
            $i++
        }
    }

    # Built for the DEVICE's shell (Linux), so this stays sh syntax.
    $qContainer = Format-PlusShArg $container
    $shLogArgs = ''
    if ($logArgs.Count -gt 0) {
        $shLogArgs = (($logArgs | ForEach-Object { Format-PlusShArg $_ }) -join ' ') + ' '
    }
    $script = @"
matches=`$(balena ps --format '{{.ID}} {{.Names}}' | grep -- $qContainer)
count=`$(printf '%s\n' "`$matches" | grep -c .)
if [ "`$count" -ne 1 ]; then
    echo "Error: expected 1 container matching $qContainer, found `$count:" >&2
    [ "`$count" -gt 0 ] && printf '%s\n' "`$matches" >&2
    balena ps --format '  {{.Names}}' >&2
    exit 1
fi
exec balena logs $shLogArgs`${matches%% *}
"@

    Write-PlusShow "balena device ssh $uuid"
    Write-PlusShow "  (on host) balena ps | grep $qContainer"
    Write-PlusShow "  (on host) balena logs $shLogArgs<container-id>"
    Invoke-PlusHostExec -Uuid $uuid -Script $script
}

function Invoke-PlusPs {
    param([string[]] $Rest)
    if ($Rest.Count -lt 1) { throw 'usage: balena ps <device> [ps opts]' }
    $uuid = Resolve-PlusUuid -Query $Rest[0]
    $tail = @($Rest | Select-Object -Skip 1)
    $shArgs = ''
    if ($tail.Count -gt 0) {
        $shArgs = ' ' + (($tail | ForEach-Object { Format-PlusShArg $_ }) -join ' ')
    }
    Write-PlusShow "balena device ssh $uuid"
    Write-PlusShow "  (on host) balena ps$shArgs"
    Invoke-PlusHostExec -Uuid $uuid -Script "balena ps$shArgs"
}

function Invoke-PlusUuid {
    param([string[]] $Rest)
    if ($Rest.Count -ne 1) { throw 'usage: balena uuid <device>' }
    return Resolve-PlusUuid -Query $Rest[0]
}

function Invoke-PlusDevices {
    # Unlike the bash version this emits objects rather than formatted text,
    # so it can be piped:  balena devices | Where-Object Status -eq online
    param([string[]] $Rest)
    Write-PlusShow 'balena device list'
    $filter = ''
    if ($Rest.Count -ge 1) { $filter = $Rest[0].ToLowerInvariant() }

    Get-PlusDeviceList |
        Where-Object {
            -not $filter -or ($_.device_name -and $_.device_name.ToLowerInvariant().Contains($filter))
        } |
        ForEach-Object {
            $status = 'offline'
            if ($_.is_online) { $status = 'online' }
            [PSCustomObject]@{
                Name   = $_.device_name
                Uuid   = $_.uuid.Substring(0, 7)
                Status = $status
                Fleet  = Get-PlusFleetName -Device $_
            }
        } |
        Sort-Object Name
}

function Invoke-PlusPassthrough {
    # Pass through to balena, resolving device names in the obvious slots.
    param([string[]] $Rest)
    $a = @($Rest)

    # 'device list' and 'device register' take a fleet, not a device.
    if ($a.Count -ge 3 -and $a[0] -eq 'device' -and $a[2] -notlike '-*' `
            -and $a[1] -ne 'list' -and $a[1] -ne 'register') {
        $a[2] = Resolve-PlusUuid -Query $a[2]
    }
    for ($i = 0; $i -lt $a.Count - 1; $i++) {
        if ($a[$i] -eq '--device') {
            $a[$i + 1] = Resolve-PlusUuid -Query $a[$i + 1]
        }
    }

    Write-PlusShow "balena $(Format-PlusArgs $a)"
    $cli = Get-PlusCli
    & $cli @a
}

# ------------------------------------------------------------- update checking

function Enable-PlusTls12 {
    # Windows PowerShell 5.1 on older builds still negotiates TLS 1.0 by
    # default, which GitHub refuses. Harmless everywhere else.
    try {
        $tls12 = [System.Net.SecurityProtocolType]::Tls12
        if (([System.Net.ServicePointManager]::SecurityProtocol -band $tls12) -ne $tls12) {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor $tls12
        }
    } catch { }
}

function Get-PlusGitRemoteHead {
    # The bash version's 'GIT_TERMINAL_PROMPT=0 timeout 5 git ls-remote'.
    # Returns the remote main SHA, or $null for any reason at all.
    #
    # Spawned through System.Diagnostics.Process rather than the call
    # operator, because both halves of that bash line need it here:
    #
    #   * PowerShell has no 'timeout', and this module runs inside the user's
    #     shell rather than as a subprocess, so an unbounded ls-remote against
    #     a black-holed network would hang their command instead of costing
    #     five seconds once a day.
    #   * Assigning $env:GIT_TERMINAL_PROMPT the obvious way would outlive the
    #     check for the rest of the session, quietly turning a later 'git
    #     clone' of a private repo into a failure rather than a prompt. On the
    #     child's own environment block it cannot escape.
    param([string] $GitPath)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GitPath
    # .Arguments, not .ArgumentList: the latter is .NET Core only, and this
    # has to run on the .NET Framework under Windows PowerShell 5.1.
    $psi.Arguments              = "ls-remote `"$script:UpstreamUrl`" main"
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    # Git Credential Manager is the default on Windows and has its own opinion
    # about popping up a dialog; GIT_TERMINAL_PROMPT alone does not stop it.
    $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Drain both pipes asynchronously: a synchronous ReadToEnd would
        # deadlock against WaitForExit if git filled the other buffer.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(5000)) {
            # Kill() and not Kill($true): killing the whole tree needs .NET
            # Core 3.0, and 5.1 is on the Framework. Anything git spawned (a
            # credential helper, ssh) is left to time out on its own -- which
            # is survivable for a once-a-day check, and the point here is that
            # the *user's command* stops waiting on it.
            try { $proc.Kill() } catch { }
            return $null
        }
        if ($proc.ExitCode -ne 0) { return $null }
        # WaitForExit(timeout) does not promise the async readers have
        # finished, so bound that wait too rather than blocking on .Result.
        if (-not $stdout.Wait(2000)) { return $null }
        $line = @($stdout.Result -split "`r?`n" | Where-Object { $_ })[0]
        if ($line) { return ($line -split '\s+')[0] }
        return $null
    } catch {
        return $null
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
}

function Test-PlusUpdate {
    # The home-manager-news equivalent: say once a day when the repo has moved
    # on. Never blocks, never fails a command, and says nothing at all when
    # this was not installed from a known revision.
    if ($env:BALENA_PLUS_NO_UPDATE_CHECK -eq '1') { return }
    if ($script:SelfRev -eq 'unknown') { return }

    try {
        # Stamp before asking, so a flaky network cannot retry on every command.
        if (Test-Path -LiteralPath $script:UpdateStamp) {
            $age = (Get-Date) - (Get-Item -LiteralPath $script:UpdateStamp).LastWriteTime
            if ($age.TotalDays -lt 1) { return }
        }
        if (-not (Test-Path -LiteralPath $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:UpdateStamp -Value (Get-Date).ToString('o')

        Enable-PlusTls12
        $latest = $null
        $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue
        if ($git) {
            # git first, because it is the only one of the two that can see a
            # repo gone private -- the API call below is unauthenticated.
            $latest = Get-PlusGitRemoteHead -GitPath $git.Source
        }
        if (-not $latest) {
            $headers = @{ 'User-Agent' = 'balena-plus'; 'Accept' = 'application/vnd.github.sha' }
            $latest = (Invoke-RestMethod -Uri $script:ApiUrl -Headers $headers -TimeoutSec 5).Trim()
        }
        if ($latest -and $latest -ne $script:SelfRev) {
            Write-Host 'balena-plus: an update is available -- run Update-BalenaPlus' -ForegroundColor DarkGray
        }
    } catch {
        # Offline, rate-limited, repo gone private: none of it is this
        # command's problem.
    }
}

function Update-BalenaPlus {
    <#
    .SYNOPSIS
        Re-run the balena-plus installer to pick up the latest version.
    .DESCRIPTION
        Fetches windows/install.ps1 from the upstream repo and runs it. The
        installer is idempotent: it upgrades in place rather than duplicating
        anything, and asks before each step.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:InstallUrl, 'Download and run the balena-plus installer')) {
        return
    }
    Enable-PlusTls12
    Write-Host "Fetching $script:InstallUrl" -ForegroundColor DarkGray
    $sb = [scriptblock]::Create((Invoke-RestMethod -Uri $script:InstallUrl -TimeoutSec 30))
    & $sb
}

# ------------------------------------------------------------------ completion

function Get-PlusCompletionDevice {
    # Device names for tab completion. Refetches if the cache is missing or
    # over 10 minutes old. Never prompts for login; returns nothing on failure.
    $fresh = $false
    if (Test-Path -LiteralPath $script:NamesCache) {
        $age = (Get-Date) - (Get-Item -LiteralPath $script:NamesCache).LastWriteTime
        if ($age.TotalMinutes -lt 10) { $fresh = $true }
    }
    if (-not $fresh) {
        try {
            Write-PlusNamesCache -Devices (Invoke-PlusCliJson -CliArgs @('device', 'list', '--json'))
        } catch { }
    }
    try {
        return @(Get-Content -LiteralPath $script:NamesCache -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Get-PlusBalenaCommand {
    # balena-cli's oclif autocomplete plugin emits bash and zsh, never
    # PowerShell, so there is no generated file to source the way the bash
    # version does. Parse the top-level command list out of 'balena help'
    # instead, cached for 30 days, and fall back to a baked-in list.
    $cached = $null
    if (Test-Path -LiteralPath $script:CommandsCache) {
        $age = (Get-Date) - (Get-Item -LiteralPath $script:CommandsCache).LastWriteTime
        if ($age.TotalDays -lt 30) {
            try { $cached = @(Get-Content -LiteralPath $script:CommandsCache -ErrorAction Stop) } catch { }
        }
    }
    if ($cached -and $cached.Count -gt 0) { return $cached }

    $parsed = @()
    try {
        $cli = Get-PlusCli
        $help = & $cli help 2>$null
        # Command lines look like "  device <subcommand>   description".
        $parsed = @($help |
            ForEach-Object {
                if ($_ -match '^\s{2,}([a-z][a-z0-9-]*)\s') { $Matches[1] }
            } |
            Sort-Object -Unique)
    } catch { }

    if ($parsed.Count -lt 5) { $parsed = $script:FallbackBalenaCommands }

    try {
        if (-not (Test-Path -LiteralPath $script:CacheDir)) {
            New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:CommandsCache -Value $parsed -Encoding UTF8
    } catch { }
    return $parsed
}

$script:PlusCompleter = {
    # Native-completer signature (three parameters). See the registration at
    # the bottom of this file for why this is -Native and not -ParameterName.
    param($wordToComplete, $commandAst, $cursorPosition)

    $words = @($commandAst.CommandElements | ForEach-Object { $_.ToString() })
    # Index into $words of the word being completed. Element 0 is the command
    # itself, so element 1 is the first argument.
    if ($wordToComplete) { $idx = $words.Count - 1 } else { $idx = $words.Count }

    # A leading -v/--verbose or -q/--quiet shifts every position by one.
    $off = 0
    if ($words.Count -gt 1 -and @('-v', '--verbose', '-q', '--quiet') -contains $words[1]) { $off = 1 }

    $cmd = ''
    if ($words.Count -gt (1 + $off)) { $cmd = $words[1 + $off] }

    $suggest = @()
    $previous = ''
    if ($idx -ge 1 -and $words.Count -ge $idx) { $previous = $words[$idx - 1] }

    if ($previous -eq '--device') {
        $suggest = Get-PlusCompletionDevice
    } elseif ($idx -eq (1 + $off)) {
        $suggest = @($script:PlusCommands) + @(Get-PlusBalenaCommand) | Sort-Object -Unique
    } elseif (@('ssh', 'tunnel', 'logs', 'ps', 'uuid') -contains $cmd -and $idx -eq (2 + $off)) {
        $suggest = Get-PlusCompletionDevice
    } elseif ($cmd -eq 'device' -and $idx -eq (3 + $off) -and $wordToComplete -notlike '-*') {
        $sub = ''
        if ($words.Count -gt (2 + $off)) { $sub = $words[2 + $off] }
        if ($sub -ne 'list' -and $sub -ne 'register') {
            $suggest = Get-PlusCompletionDevice
        }
    }

    $suggest |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(
                $_, $_, 'ParameterValue', $_)
        }
}

# --------------------------------------------------------------- entry points

function Get-PlusUsage {
    return @'
Usage: balena [-v|--verbose|-q|--quiet] <command> [args...]

Thin wrapper around the balena CLI that:
  - runs 'balena login --web' automatically if not logged in
  - accepts device names (exact, or a unique substring) anywhere
    a device UUID is expected; a fleet name brings up an fzf device
    picker (BALENA_PLUS_PICKER=select for a plain numbered menu)
  - adds a few convenience commands (logs, ps, uuid, devices, tunnel)

  -q, --quiet     Do not print the equivalent raw balena command, which is
                  otherwise printed before every command.
                  BALENA_PLUS_QUIET=1 does the same for every invocation.
  -v, --verbose   Print it even when BALENA_PLUS_QUIET=1 is set. A bare
                  'balena -v' still prints the CLI version.

Commands:
  ssh <device> [service]            SSH into the host OS (or a service container)
  tunnel <device> <port...>         Tunnel device ports to localhost. A port is
                                    <remote>[:[localIP:]local]; the -p the raw
                                    CLI wants is optional. Repeat for more ports.
  logs <device> <container> [opts]  Container logs via the host's balena engine
                                    opts: -f, -n/--tail N, -t, or any 'balena logs' flag
  ps <device> [ps opts]             'balena ps' on the device host
  uuid <device>                     Print the full UUID for a device name
  devices [filter]                  List devices as objects (Name, Uuid, Status,
                                    Fleet), so they can be piped and filtered
  <anything else>                   Passed through to balena; the device
                                    argument of 'device <sub> <device>' and
                                    '--device <device>' is resolved by name

Examples:
  balena ssh foo-device
  balena logs foo-device bar-app -f -n 200
  balena tunnel foo-device 8080:3000      (device 8080 -> localhost:3000)
  balena tunnel foo-device -p 22222       (the raw CLI's spelling also works)
  balena tunnel foo-device 8080 9000:9001 (several ports at once)
  balena ssh foo-fleet          (pick a device from the fleet)
  balena device restart foo-device
  balena -q logs foo-device bar-app -f    (without the raw command lines)
  balena devices | Where-Object Status -eq online

The raw CLI is still at 'balena-raw', e.g. 'balena-raw help'. (The bash
version spells this '\balena'; PowerShell has no equivalent syntax.)
It is whatever balena-cli is on your PATH -- this wrapper does not ship one.

Update-BalenaPlus          re-runs the installer to upgrade in place.

BALENA_PLUS_QUIET=1 silences the raw balena command lines for good.
BALENA_PLUS_NO_UPDATE_CHECK=1 silences the once-a-day "update available" line.
BALENA_PLUS_PICKER selects the fleet picker: fzf, grid or select.
'@
}

function Invoke-BalenaRaw {
    <#
    .SYNOPSIS
        Run the real balena CLI, bypassing the balena-plus wrapper.
    .DESCRIPTION
        The PowerShell equivalent of the bash version's '\balena'. No device
        name resolution, no login check, no printed command line.

        Deliberately a simple function -- see Invoke-BalenaPlus for why.
    #>
    $cli = Get-PlusCli
    if ($args.Count -gt 0) { & $cli @args } else { & $cli }
}

function Invoke-BalenaPlus {
    <#
    .SYNOPSIS
        Thin wrapper around the balena CLI: device-name resolution, fleet
        picker, login on demand, and ssh/tunnel/logs/ps/uuid/devices helpers.
    .DESCRIPTION
        See 'balena help' for the full command list.

        This is a SIMPLE function on purpose: no param() block, no
        [Parameter()] attribute, arguments collected from $args.

        Declaring a parameter -- even just
            param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
        -- makes this an *advanced* function, and PowerShell then grafts the
        common parameters onto it. Those poison exactly the flags a CLI
        wrapper has to forward:

            balena tunnel dev -p 8080   ->  error: 'p' is ambiguous,
                                            matches -ProgressAction,
                                            -PipelineVariable
            balena ssh dev -v           ->  '-v' silently binds to -Verbose
                                            and never reaches balena

        The silent one is the dangerous one. -d, -e, -w, -o and -i break the
        same way. A simple function has no common parameters, so every flag
        lands in $args untouched.

        Tab completion still works: Register-ArgumentCompleter -Native fires
        for simple functions, which is why the registration at the bottom of
        this file uses -Native rather than -ParameterName.
    #>

    # Memo is per top-level invocation: a long-lived shell session must not
    # keep serving a device list fetched an hour ago.
    $script:DeviceList = $null

    $script:Verbose = $true
    if ($env:BALENA_PLUS_QUIET -eq '1') { $script:Verbose = $false }

    $rest = @($args)

    # A leading -v/--verbose or -q/--quiet overrides the default for this one
    # command. A bare 'balena -v' is the exception: with no command after it
    # that is the CLI's own version flag, so it is passed straight through.
    if ($rest.Count -ge 1) {
        if ($rest[0] -eq '-q' -or $rest[0] -eq '--quiet') {
            $script:Verbose = $false
            $rest = @($rest | Select-Object -Skip 1)
        } elseif (($rest[0] -eq '-v' -or $rest[0] -eq '--verbose') -and $rest.Count -ge 2) {
            $script:Verbose = $true
            $rest = @($rest | Select-Object -Skip 1)
        }
    }

    if ($rest.Count -eq 0 -or $rest[0] -eq '-h' -or $rest[0] -eq '--help' -or $rest[0] -eq 'help') {
        Get-PlusUsage
        return
    }

    try {
        Test-PlusLogin
        Test-PlusUpdate

        $command = $rest[0]
        $tail = @($rest | Select-Object -Skip 1)

        switch ($command) {
            'ssh'     { Invoke-PlusSsh     -Rest $tail }
            'tunnel'  { Invoke-PlusTunnel  -Rest $tail }
            'logs'    { Invoke-PlusLogs    -Rest $tail }
            'ps'      { Invoke-PlusPs      -Rest $tail }
            'uuid'    { Invoke-PlusUuid    -Rest $tail }
            'devices' { Invoke-PlusDevices -Rest $tail }
            default   { Invoke-PlusPassthrough -Rest $rest }
        }
    } catch {
        # Never 'exit' here: this runs inside the user's own shell.
        Write-Error $_.Exception.Message -ErrorAction Continue
        $global:LASTEXITCODE = 1
    }
}

Set-Alias -Name 'balena'      -Value 'Invoke-BalenaPlus' -Force
Set-Alias -Name 'balena-plus' -Value 'Invoke-BalenaPlus' -Force
Set-Alias -Name 'balena-raw'  -Value 'Invoke-BalenaRaw'  -Force

# -Native, not -ParameterName. The entry point is a simple function so that
# flags like -p and -v survive (see Invoke-BalenaPlus), which leaves it with
# no parameter to hang a completer on -- but a native completer fires for it
# anyway. Both the function name and the aliases are registered because the
# two completer kinds disagree about which one they see.
Register-ArgumentCompleter -CommandName 'Invoke-BalenaPlus', 'balena', 'balena-plus' `
    -Native -ScriptBlock $script:PlusCompleter

Export-ModuleMember `
    -Function @('Invoke-BalenaPlus', 'Invoke-BalenaRaw', 'Update-BalenaPlus') `
    -Alias @('balena', 'balena-plus', 'balena-raw')
