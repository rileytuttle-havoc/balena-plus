# balena-plus for Windows

The Windows PowerShell port of [`balena-plus.sh`](../balena-plus.sh). Same
idea, same commands, same output format — a thin wrapper around the balena
CLI that resolves device names, picks a device out of a fleet, and prints the
raw balena command before running it.

A separate implementation rather than a translation, so that changes here
cannot break the bash version.

## Install

```powershell
irm https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1 | iex
```

It explains what it is about to do and asks before each step (`y`, `N`, or `Y`
for yes-to-all). Safe to re-run: it upgrades in place rather than duplicating
anything.

To pass switches, build a scriptblock — `iex` cannot forward arguments:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1))) -Yes
```

| Switch | |
|---|---|
| `-Yes` | answer yes to every prompt |
| `-SkipProfile` | do not offer to touch your PowerShell profile |
| `-Uninstall` | remove the module and the profile line |

**It will not install a second balena CLI.** balena-plus wraps whatever
`balena` is already on your PATH. If you do not have one, the installer offers
`npm install -g balena-cli` when npm is present, and otherwise points you at
the official installer.

The installer handles two Windows-specific snags on its own:

- **Execution policy.** This script runs from memory, so it is exempt — but
  the module it installs is a `.psm1` on disk and is not. If your policy is
  `Restricted` or `AllSigned`, it offers `Set-ExecutionPolicy -Scope
  CurrentUser RemoteSigned`, which affects your account only.
- **Mark of the web.** Downloaded files are `Unblock-File`d, so `RemoteSigned`
  does not refuse them.

Installed to `%LOCALAPPDATA%\balena-plus\BalenaPlus`. Uninstalling is deleting
that folder and the two profile lines, which is all `-Uninstall` does.

## Then

The installer offers to add this to your `$PROFILE`, or you can add it
yourself:

```powershell
Import-Module "$env:LOCALAPPDATA\balena-plus\BalenaPlus\BalenaPlus.psd1"
```

That makes `balena` the wrapper and turns on tab completion for device and
fleet names. Open a new PowerShell window and try `balena devices`.

## Differences from the bash version

Everything in `balena help` works the same. These are the deliberate
divergences:

| | bash | PowerShell |
|---|---|---|
| Raw CLI escape | `\balena` | `balena-raw` — PowerShell has no `\cmd` syntax |
| Shell glue | `eval "$(balena-plus shell-init bash)"` | `Import-Module` — so there is no `shell-init` command |
| `devices` output | formatted text | objects: `balena devices \| Where-Object Status -eq online` |
| Upgrade | `nix profile upgrade` | `Update-BalenaPlus`, which re-runs the installer |
| Fleet picker | fzf, else `select` menu | fzf, else a numbered menu; `BALENA_PLUS_PICKER=grid` for `Out-GridView` |
| Dependencies | `python3`, optional `fzf` | none — `ConvertFrom-Json` is built in |

Environment variables (`BALENA_PLUS_QUIET`, `BALENA_PLUS_NO_UPDATE_CHECK`,
`BALENA_PLUS_PICKER`) behave identically.

## Requirements

Windows PowerShell 5.1 — what ships with Windows 10 and 11, so nothing to
install. It also runs on PowerShell 7.

`balena` is required and is yours, not one this ships. `fzf` is optional and
only improves the fleet picker. `git` is optional and only used by the
once-a-day update check, which falls back to the GitHub API.

## Hacking

```powershell
powershell -NoProfile -File windows\tests\BalenaPlus.Tests.ps1
pwsh       -NoProfile -File windows/tests/BalenaPlus.Tests.ps1
```

79 tests, no Pester dependency, no account or network needed — a fake balena
CLI is put on PATH for the duration. **Worth running under Windows PowerShell
5.1 specifically**, since that is the version being targeted.

Linting, which is where most of the 5.1 coverage comes from when you are not
on Windows:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows\PSScriptAnalyzerSettings.psd1
```

### Testing it without a Windows machine

This targets Windows PowerShell 5.1 and is developed on Linux, so the
question is how much 5.1 you can get without booting one. In order of how
much infrastructure it costs:

**1. pwsh 7, seconds, no VM.** The whole suite runs on Linux:

```bash
nix shell nixpkgs#powershell --command pwsh -NoProfile -File windows/tests/BalenaPlus.Tests.ps1
```

Everything that is not edition-specific is covered here, which is most of it.

**2. The analyzer's 5.1 compatibility profiles, also seconds.**
`PSUseCompatibleSyntax`, `PSUseCompatibleCommands` and `PSUseCompatibleTypes`
in [`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1) check the
source against a captured profile of a real 5.1 install — 7-only syntax,
cmdlets, cmdlet *parameters* (`ConvertFrom-Json -AsHashtable`) and .NET types
(`System.Text.Json`) are all caught statically. This is as close to 5.1 as
you get without it.

**3. A real 5.1 in one command.** Windows containers share the host kernel,
so there is no Linux-hosted `servercore` image and no Wine route either —
anything that runs 5.1 is a VM underneath. [dockur/windows] is the smallest
amount of ceremony around that: a container that installs Windows unattended
on KVM, with the repo mounted in. [`docker-compose.yml`](docker-compose.yml)
is that, pre-wired:

```bash
mkdir -p .win   # or the daemon creates it root-owned
docker compose -f windows/docker-compose.yml up -d
```

You need `/dev/kvm` (so, hardware virtualization enabled in firmware) and
membership in the `docker` group; nothing else. First boot downloads ~6 GB
and installs Windows Server 2022 unattended over 15-25 minutes — watch it at
<http://127.0.0.1:8006>, answer nothing. Later boots take about a minute,
because `.win/` holds the disk between runs. `docker compose down` shuts the
guest down cleanly; deleting `.win/` starts the install over.

The repo is mounted read-write as drive `Z:` in the guest, live — edits on
either side show up immediately on the other, so there is no copy step and a
Windows-side edit lands in your real working tree. Run the suite with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Z:\windows\tests\BalenaPlus.Tests.ps1
```

`powershell.exe` rather than `pwsh` is the whole point — that is 5.1.
`-ExecutionPolicy Bypass` is needed because a mapped drive counts as the
remote zone, which `RemoteSigned` refuses.

Once installed, prefer RDP over the web viewer, which is sluggish and has no
clipboard sharing. The login is `Docker` / `admin`:

```bash
xfreerdp3 /v:127.0.0.1 /u:Docker /p:admin /dynamic-resolution
```

To drive it from the Linux side without clicking into the VM at all, turn on
the guest's OpenSSH server once:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service sshd -StartupType Automatic; Start-Service sshd
New-NetFirewallRule -Name sshd -DisplayName 'SSH' -Enabled True `
  -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

The compose file already publishes `127.0.0.1:2222` for it, and the whole
loop collapses to one line you can rerun after every edit:

```bash
ssh -p 2222 Docker@127.0.0.1 'powershell -NoProfile -ExecutionPolicy Bypass -File Z:\windows\tests\BalenaPlus.Tests.ps1'
```

(dockur documents the forwarding of 8006 and 3389 but not of arbitrary
published ports, so confirm 2222 actually reaches the guest the first time;
if it does not, RDP still works and the published port costs nothing.)

Everything here is bound to loopback deliberately: the guest has a published
password in a committed file and no business being reachable from the LAN.
Swap `VERSION: "2022"` for `core11` — Tiny11 Core, 3 GB — if you want the
smallest thing with 5.1 on it and don't mind an unofficial stripped build.

What (1) and (2) cannot see is the genuinely edition-specific handful:
whether `Register-ArgumentCompleter -Native` fires for a simple function on
5.1, .NET Framework-only method overloads, and 5.1's console encoding
defaults. Those want (3), or your VM, at least once per change that touches
them.

[dockur/windows]: https://github.com/dockur/windows

### One design note worth knowing

`Invoke-BalenaPlus` is a *simple* function — no `param()` block, arguments
read from `$args`. This looks like an oversight and is not.

Declaring a parameter, even just

```powershell
param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
```

makes it an *advanced* function, and PowerShell then adds the common
parameters to it. Those collide with exactly the flags a CLI wrapper has to
forward:

```
balena tunnel dev -p 8080   ->  error: 'p' is ambiguous, matches
                                -ProgressAction and -PipelineVariable
balena ssh dev -v           ->  '-v' binds to -Verbose and never
                                reaches balena, silently
```

`-d`, `-e`, `-w`, `-o` and `-i` break the same way, and the silent ones are
the dangerous ones. A simple function has no common parameters, so every flag
lands in `$args` untouched. There are regression tests for all seven.

Tab completion still works, because `Register-ArgumentCompleter -Native`
fires for simple functions — which is why the registration uses `-Native`
rather than `-ParameterName`.
