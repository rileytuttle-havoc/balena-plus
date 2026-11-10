<#
    A stand-in for the balena CLI, so the wrapper can be tested without an
    account, a network, or a device. Invoked through a shim named 'balena'
    that the test harness puts on PATH (see BalenaPlus.Tests.ps1), because
    the module finds the CLI with Get-Command -CommandType Application.

    Every invocation appends its argv to calls.log, and 'device ssh' saves
    whatever was piped to it, so tests can assert on both.
#>

$cap = $env:FAKE_BALENA_CAPTURE
if (-not $cap) { $cap = Join-Path ([System.IO.Path]::GetTempPath()) 'fake-balena' }
if (-not (Test-Path -LiteralPath $cap)) { New-Item -ItemType Directory -Path $cap -Force | Out-Null }
Add-Content -LiteralPath (Join-Path $cap 'calls.log') -Value ($args -join ' ')

$devices = @'
[
 {"uuid":"aaaa1111aaaa1111aaaa1111aaaa1111","device_name":"sensor-01","is_online":true,"fleet":"riley/field-fleet"},
 {"uuid":"bbbb2222bbbb2222bbbb2222bbbb2222","device_name":"sensor-02","is_online":false,"fleet":"riley/field-fleet"},
 {"uuid":"cccc3333cccc3333cccc3333cccc3333","device_name":"gateway-a","is_online":true,"fleet":{"app_name":"lab","slug":"riley/lab"}},
 {"uuid":"dddd4444dddd4444dddd4444dddd4444","device_name":"edge-node","is_online":true,"fleet":["riley/lab"]}
]
'@

$fleets = @'
[
 {"app_name":"field-fleet","slug":"riley/field-fleet"},
 {"app_name":"lab","slug":"riley/lab"}
]
'@

$a0 = ''; $a1 = ''; $a2 = ''; $a3 = ''
if ($args.Count -gt 0) { $a0 = [string]$args[0] }
if ($args.Count -gt 1) { $a1 = [string]$args[1] }
if ($args.Count -gt 2) { $a2 = [string]$args[2] }
if ($args.Count -gt 3) { $a3 = [string]$args[3] }

if ($a0 -eq 'whoami') { Write-Output 'riley'; exit 0 }
if ($a0 -eq 'fleet' -and $a1 -eq 'list') { Write-Output $fleets; exit 0 }

if ($a0 -eq 'device' -and $a1 -eq 'list') {
    if ($a2 -eq '--fleet') {
        # field-fleet has two devices so the picker has something to pick;
        # every other fleet has exactly one, which auto-selects.
        if ($a3 -eq 'riley/field-fleet') {
            Write-Output (($devices | ConvertFrom-Json) | Where-Object { $_.device_name -like 'sensor-*' } | ConvertTo-Json -Depth 5)
        } else {
            Write-Output (($devices | ConvertFrom-Json) | Where-Object { $_.device_name -eq 'gateway-a' } | ConvertTo-Json -Depth 5)
        }
        exit 0
    }
    Write-Output $devices
    exit 0
}

if ($a0 -eq 'device' -and $a1 -eq 'ssh') {
    $stdin = [Console]::In.ReadToEnd()
    [System.IO.File]::WriteAllText((Join-Path $cap 'ssh-stdin.bin'), $stdin)
    Write-Output "[fake ssh to $a2]"
    exit 0
}

if ($a0 -eq 'help') {
    @'
USAGE
  $ balena [COMMAND]

COMMANDS
  device       manage devices
  fleet        manage fleets
  deploy       deploy a release
  push         push to a fleet
  logs         show device logs
  ssh          ssh into a device
'@
    exit 0
}

Write-Output "[fake balena] $($args -join ' ')"
exit 0
