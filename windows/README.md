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
pwsh -NoProfile -File windows\tests\BalenaPlus.Tests.ps1
```

63 tests, no Pester dependency, no account or network needed — a fake balena
CLI is put on PATH for the duration. **Worth running under Windows PowerShell
5.1 specifically**, since that is the version being targeted:

```powershell
powershell -NoProfile -File windows\tests\BalenaPlus.Tests.ps1
```

Linting, including the 5.1 compatibility rules that catch PowerShell 7-only
syntax:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows\PSScriptAnalyzerSettings.psd1
```

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
