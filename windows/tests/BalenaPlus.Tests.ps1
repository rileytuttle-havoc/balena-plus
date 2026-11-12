<#
.SYNOPSIS
    Tests for the BalenaPlus module. No account, network or device needed.

.DESCRIPTION
    Run from anywhere:

        powershell -NoProfile -File windows\tests\BalenaPlus.Tests.ps1
        pwsh       -NoProfile -File windows/tests/BalenaPlus.Tests.ps1

    Worth running under Windows PowerShell 5.1 specifically, since that is
    the version the module targets and the one whose parameter binding broke
    the first draft of this port.

    No Pester dependency on purpose: this has to be runnable on a stock
    Windows box with nothing installed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$Root      = Split-Path $PSScriptRoot -Parent
$Manifest  = Join-Path (Join-Path $Root 'BalenaPlus') 'BalenaPlus.psd1'
$Work      = Join-Path ([System.IO.Path]::GetTempPath()) ("balena-plus-tests-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$FakeBin   = Join-Path $Work 'bin'
$Capture   = Join-Path $Work 'capture'
$AppData   = Join-Path $Work 'appdata'

# $IsWindows only exists on PowerShell 6+; on 5.1 it is simply absent.
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

New-Item -ItemType Directory -Force -Path $FakeBin, $Capture, $AppData | Out-Null

# A shim named 'balena' on PATH, because the module locates the CLI with
# Get-Command -CommandType Application -- which only matches real executables.
$fake = Join-Path $PSScriptRoot 'fake-balena.ps1'

# The PowerShell that the shim should re-enter. $PSHOME is the reliable
# answer on both editions; BALENA_PLUS_TEST_HOST is an escape hatch for
# unusual installs where the process path is not the interpreter.
$host_exe = $env:BALENA_PLUS_TEST_HOST
if (-not $host_exe) {
    if ($PSVersionTable.PSVersion.Major -lt 6) { $exeName = 'powershell' } else { $exeName = 'pwsh' }
    if ($onWindows) { $exeName = $exeName + '.exe' }
    $candidate = Join-Path $PSHOME $exeName
    if (Test-Path -LiteralPath $candidate) { $host_exe = $candidate }
    else { $host_exe = (Get-Process -Id $PID).Path }
}
if ($onWindows) {
    $shim = Join-Path $FakeBin 'balena.cmd'
    Set-Content -LiteralPath $shim -Encoding ASCII -Value @(
        '@echo off',
        "`"$host_exe`" -NoProfile -ExecutionPolicy Bypass -File `"$fake`" %*"
    )
} else {
    $shim = Join-Path $FakeBin 'balena'
    Set-Content -LiteralPath $shim -Encoding ASCII -Value @(
        '#!/bin/sh',
        "exec `"$host_exe`" -NoProfile -File `"$fake`" `"`$@`""
    )
    & /bin/chmod +x $shim
}

$env:PATH = $FakeBin + [System.IO.Path]::PathSeparator + $env:PATH
$env:LOCALAPPDATA = $AppData
$env:FAKE_BALENA_CAPTURE = $Capture
$env:BALENA_PLUS_NO_UPDATE_CHECK = '1'
$env:BALENA_PLUS_QUIET = $null

Import-Module $Manifest -Force

$script:pass = 0
$script:fail = 0
function T {
    param($Name, $Want, $Got)
    if ("$Got" -eq "$Want") {
        $script:pass++
        Write-Host "  ok   $Name" -ForegroundColor DarkGray
    } else {
        $script:fail++
        Write-Host "  FAIL $Name" -ForegroundColor Red
        Write-Host "         want: $Want" -ForegroundColor Red
        Write-Host "         got : $Got" -ForegroundColor Red
    }
}
function Section { param($Text) Write-Host "=== $Text ===" -ForegroundColor White }
function Calls { Get-Content (Join-Path $Capture 'calls.log') -ErrorAction SilentlyContinue }
function ClearCalls { Remove-Item (Join-Path $Capture 'calls.log') -ErrorAction SilentlyContinue }
function LastCall { $c = @(Calls); if ($c.Count) { return $c[-1] } return '' }
function Comp {
    param($Line)
    $r = [System.Management.Automation.CommandCompletion]::CompleteInput($Line, $Line.Length, $null)
    return @($r.CompletionMatches.CompletionText)
}

try {

Section 'name resolution'
T 'exact name'     'aaaa1111aaaa1111aaaa1111aaaa1111' (balena uuid sensor-01 6>$null)
T 'uuid prefix'    'cccc3333cccc3333cccc3333cccc3333' (balena uuid cccc333 6>$null)
T 'name substring' 'cccc3333cccc3333cccc3333cccc3333' (balena uuid gate 6>$null)
T 'ambiguous names both' $true ((balena uuid sensor-0 2>&1 6>$null | Out-String) -match 'sensor-01, sensor-02')
T 'no match errors'      $true ((balena uuid no-such 2>&1 6>$null | Out-String) -match 'no device or fleet matching')
T 'fleet -> sole device' 'cccc3333cccc3333cccc3333cccc3333' (balena uuid lab 6>$null)

Section 'devices emits objects'
$d = @(balena devices 6>$null)
T 'count'            4          $d.Count
T 'is object'        $true      ($d[0] -is [PSCustomObject])
T 'sorted by name'   'edge-node' $d[0].Name
T 'short uuid'       'aaaa111'  ($d | Where-Object Name -eq 'sensor-01').Uuid
T 'online'           'online'   ($d | Where-Object Name -eq 'sensor-01').Status
T 'offline'          'offline'  ($d | Where-Object Name -eq 'sensor-02').Status
T 'pipeable'         3          (@($d | Where-Object Status -eq 'online')).Count
T 'fleet as string'  'riley/field-fleet' ($d | Where-Object Name -eq 'sensor-01').Fleet
T 'fleet as object'  'lab'               ($d | Where-Object Name -eq 'gateway-a').Fleet
T 'fleet as array'   'riley/lab'         ($d | Where-Object Name -eq 'edge-node').Fleet
T 'name filter'      2          (@(balena devices sensor 6>$null)).Count

Section 'tunnel: the -p is optional'
ClearCalls; balena tunnel sensor-01 8080:3000 6>$null | Out-Null
T 'bare mapping gets -p'  'device tunnel aaaa1111aaaa1111aaaa1111aaaa1111 -p 8080:3000' (LastCall)
ClearCalls; balena tunnel sensor-01 -p 22222 6>$null | Out-Null
T 'explicit -p kept once' 'device tunnel aaaa1111aaaa1111aaaa1111aaaa1111 -p 22222' (LastCall)
ClearCalls; balena tunnel sensor-01 8080 9000:9001 6>$null | Out-Null
T 'several ports'         'device tunnel aaaa1111aaaa1111aaaa1111aaaa1111 -p 8080 -p 9000:9001' (LastCall)

Section 'passthrough resolves the obvious device slots'
ClearCalls; balena device restart sensor-01 6>$null | Out-Null
T 'device <sub> <dev>'      'device restart aaaa1111aaaa1111aaaa1111aaaa1111' (LastCall)
ClearCalls; balena device list 6>$null | Out-Null
T 'device list takes a fleet'     'device list' (LastCall)
ClearCalls; balena device register field-fleet 6>$null | Out-Null
T 'device register takes a fleet' 'device register field-fleet' (LastCall)
ClearCalls; balena note --device gateway-a hello 6>$null | Out-Null
T '--device resolved'       'note --device cccc3333cccc3333cccc3333cccc3333 hello' (LastCall)
ClearCalls; balena device move -f lab 6>$null | Out-Null
T 'a flag is not a device'  'device move -f lab' (LastCall)

Section 'verbose and quiet'
T 'verbose by default' $true  ((balena uuid sensor-01 6>&1 | Out-String) -match '\+ balena device list')
T '-q suppresses'      $false ((balena -q uuid sensor-01 6>&1 | Out-String) -match '\+ balena')
$env:BALENA_PLUS_QUIET = '1'
T 'env quiet'          $false ((balena uuid sensor-01 6>&1 | Out-String) -match '\+ balena')
T '-v overrides env'   $true  ((balena -v uuid sensor-01 6>&1 | Out-String) -match '\+ balena')
$env:BALENA_PLUS_QUIET = $null
ClearCalls; balena -v 6>$null | Out-Null
T 'bare -v is the CLI version flag' '-v' (LastCall)

Section 'flags that advanced functions would have eaten'
# Regression guard. With a param() block these bind to PowerShell's common
# parameters instead: -p is ambiguous (-ProgressAction / -PipelineVariable)
# and -v silently disappears into -Verbose.
foreach ($flag in '-p', '-v', '-d', '-e', '-w', '-o', '-i') {
    ClearCalls
    balena someCmd dev $flag 8080 6>$null 2>$null | Out-Null
    T "flag $flag reaches the CLI" "someCmd dev $flag 8080" (LastCall)
}

Section 'logs: the script sent to the device'
ClearCalls
balena logs sensor-01 web -n 200 -f 6>$null | Out-Null
$raw = [System.IO.File]::ReadAllText((Join-Path $Capture 'ssh-stdin.bin'))
T 'ssh target'        'device ssh aaaa1111aaaa1111aaaa1111aaaa1111' (LastCall)
T '-n becomes --tail' $true ($raw -match "'--tail' '200'")
T '-f forwarded'      $true ($raw -match "'-f'")
T 'container quoted'  $true ($raw -match "grep -- 'web'")
T 'ends with exit'    $true ($raw -match "(?m)^exit\s*$")
# The device host is Linux. A stray CR would make its shell choke, and
# PowerShell appends CRLF to anything piped to a native command.
$body = $raw.Substring(0, $raw.LastIndexOf('exit'))
T 'no CR inside the script' $false ($body.Contains("`r"))

ClearCalls
balena ps sensor-01 -a 6>$null | Out-Null
T 'ps script' $true ([System.IO.File]::ReadAllText((Join-Path $Capture 'ssh-stdin.bin')) -match "^balena ps '-a'")

Section 'quoting helpers'
$m = Get-Module BalenaPlus
T 'plain'            'sensor-01' (& $m { Format-PlusArg 'sensor-01' })
T 'needs quoting'    "'a b'"     (& $m { Format-PlusArg 'a b' })
T 'doubles a quote'  "'it''s'"   (& $m { Format-PlusArg "it's" })
T 'sh plain'         "'web'"     (& $m { Format-PlusShArg 'web' })
T 'sh escapes quote' "'it'\''s'" (& $m { Format-PlusShArg "it's" })

Section 'update check: bounded, and no footprint on the session'
# This module runs inside the user's shell, so the two ways the update check
# could hurt them are hanging their command and leaving environment behind.
$slowGit = Join-Path $FakeBin ('slow-git' + $(if ($onWindows) { '.cmd' } else { '' }))
if ($onWindows) {
    # ping -n 30 is the stock way to sleep in cmd without a sleep binary.
    Set-Content -LiteralPath $slowGit -Encoding ASCII -Value @(
        '@echo off', 'ping -n 30 127.0.0.1 >nul', 'echo deadbeef refs/heads/main')
} else {
    Set-Content -LiteralPath $slowGit -Encoding ASCII -Value @(
        '#!/bin/sh', 'sleep 30', 'echo "deadbeef\trefs/heads/main"')
    & /bin/chmod +x $slowGit
}
$env:GIT_TERMINAL_PROMPT = 'sentinel'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$slowResult = & $m { param($p) Get-PlusGitRemoteHead -GitPath $p } $slowGit
$sw.Stop()
T 'a hung git is given up on'     $null  $slowResult
T 'and bounded to about 5s'       $true  ($sw.Elapsed.TotalSeconds -lt 15)
T 'session GIT_TERMINAL_PROMPT untouched' 'sentinel' $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = $null

# The happy path, against a stand-in that answers the way git does.
$fastGit = Join-Path $FakeBin ('fast-git' + $(if ($onWindows) { '.cmd' } else { '' }))
if ($onWindows) {
    Set-Content -LiteralPath $fastGit -Encoding ASCII -Value @(
        '@echo off', 'echo 1234567abcdef	refs/heads/main')
} else {
    Set-Content -LiteralPath $fastGit -Encoding ASCII -Value @(
        '#!/bin/sh', 'printf "1234567abcdef\trefs/heads/main\n"')
    & /bin/chmod +x $fastGit
}
T 'parses the sha out of ls-remote' '1234567abcdef' (& $m { param($p) Get-PlusGitRemoteHead -GitPath $p } $fastGit)
T 'a missing git is not fatal'      $null           (& $m { param($p) Get-PlusGitRemoteHead -GitPath $p } (Join-Path $FakeBin 'no-such-git'))

Section 'tab completion'
$c = Comp 'balena '
T 'offers wrapper commands' $true (($c -contains 'ssh') -and ($c -contains 'devices') -and ($c -contains 'tunnel'))
T 'offers balena commands'  $true (($c -contains 'deploy') -and ($c -contains 'push'))
T 'device slot'        'sensor-01 sensor-02' ((Comp 'balena ssh sen') -join ' ')
T 'logs device slot'   'gateway-a'           ((Comp 'balena logs gate') -join ' ')
T 'offset past -q'     'sensor-01 sensor-02' ((Comp 'balena -q ssh sen') -join ' ')
T 'device <sub> <dev>' 'sensor-01 sensor-02' ((Comp 'balena device restart sen') -join ' ')
T 'device list offers no devices' 0 (Comp 'balena device list sen').Count
T 'after --device'     'gateway-a'           ((Comp 'balena foo --device gate') -join ' ')
# Returning nothing lets PowerShell fall back to path completion, which is
# what you want for --source and image arguments. The invariant is only that
# device names stay inside device slots.
$c = Comp 'balena ssh sensor-01 '
T 'no device names past the slot' $false (($c -contains 'sensor-01') -or ($c -contains 'gateway-a'))


Section 'help needs no CLI and no account'
ClearCalls
T 'no args prints usage' $true ((balena 6>&1 | Out-String) -match 'Usage: balena')
T 'and asks balena nothing' 0 (@(Calls)).Count
T '-h'     $true ((balena -h     6>&1 | Out-String) -match 'Usage: balena')
T '--help' $true ((balena --help 6>&1 | Out-String) -match 'Usage: balena')
T 'help'   $true ((balena help   6>&1 | Out-String) -match 'Usage: balena')

Section 'balena-raw, the escape hatch'
ClearCalls
$rawOut = balena-raw note --device gateway-a hello 6>&1 | Out-String
T 'does not resolve device names' 'note --device gateway-a hello' (LastCall)
T 'prints no command line'        $false ($rawOut -match '\+ balena')

Section 'exit codes reach the caller'
# The wrapper runs inside the user's shell, so a failing balena has to leave
# $LASTEXITCODE behind rather than exiting anything.
$global:LASTEXITCODE = 0
balena exit-with 7 6>$null 2>$null | Out-Null
T 'balena''s own exit code survives' 7 $LASTEXITCODE
$global:LASTEXITCODE = 0
balena uuid no-such 6>$null 2>$null | Out-Null
T 'a wrapper error is exit 1'        1 $LASTEXITCODE
$global:LASTEXITCODE = 0
balena devices 6>$null | Out-Null
T 'success leaves it at 0'           0 $LASTEXITCODE

Section 'fleet picker: the numbered menu'
# A function in the global scope shadows the Read-Host cmdlet everywhere,
# module scope included, which is the only way to drive the menu with no
# terminal to type into. Redefined rather than parameterised, so the answer
# stays a literal and the test needs no global variable.
$env:BALENA_PLUS_PICKER = 'select'
function global:Read-Host { param([string] $Prompt) return '2' }
# field-fleet is the fake's two-device fleet: sensor-01 online, sensor-02
# not, and the picker puts online first -- so '2' is sensor-02.
T 'picks by number' 'bbbb2222bbbb2222bbbb2222bbbb2222' (balena uuid field-fleet 6>$null)
function global:Read-Host { param([string] $Prompt) return '9' }
T 'out of range is refused' $true ((balena uuid field-fleet 2>&1 6>$null | Out-String) -match 'no device selected')
Remove-Item function:global:Read-Host -ErrorAction SilentlyContinue
$env:BALENA_PLUS_PICKER = $null

Section 'Update-BalenaPlus'
$updateOk = $true
try { Update-BalenaPlus -WhatIf | Out-Null } catch { $updateOk = $false }
T '-WhatIf downloads nothing and throws nothing' $true $updateOk

Section 'no balena on PATH'
# Last, because it clears the module's cached CLI path. The shim is moved
# aside rather than the PATH edited, so Get-Command genuinely finds nothing.
$hidden = "$shim.hidden"
Move-Item -LiteralPath $shim -Destination $hidden
$global:LASTEXITCODE = 0
$missing = balena devices 2>&1 6>$null | Out-String
# Flattened, because the two error views disagree about where to wrap it and
# PowerShell 7 adds colour and a gutter. The point is only that both halves
# of the message -- the diagnosis and the fix -- survive to the user.
$esc  = [char]27
$flat = ($missing -replace "$esc\[[0-9;]*m", ' ') -replace '[\r\n|]+', ' ' -replace '\s+', ' '
T 'says what is wrong' $true ($flat -match 'balena CLI not found in PATH')
T 'and how to fix it'  $true ($flat -match "npm install -g balena-cli")
T 'and exits 1'        1     $LASTEXITCODE
Move-Item -LiteralPath $hidden -Destination $shim
} finally {
    Remove-Module BalenaPlus -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:fail -gt 0) {
    Write-Host "FAILED  $script:fail of $($script:pass + $script:fail)" -ForegroundColor Red
    exit 1
}
Write-Host "All $script:pass tests passed." -ForegroundColor Green
exit 0
