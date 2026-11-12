# balena-plus

A thin wrapper around the [balena CLI](https://github.com/balena-io/balena-cli).
It lets you say

```bash
balena ssh foo-device
```

instead of looking up a UUID, and adds a few things the raw CLI makes you work for.

- **Device names anywhere a UUID is expected** — exact name, unique substring, or
  UUID prefix. Give it a *fleet* name instead and you get an fzf picker of that
  fleet's devices, online ones first.
- **`tunnel`** — `balena tunnel foo-device 8080:3000`. The `-p` the raw CLI
  requires before each port mapping is optional.
- **`logs`** — container logs through the device's own balena engine, picking the
  container by substring.
- **`ps`**, **`uuid`**, **`devices`** — the small stuff, without the ceremony.
- Runs `balena login --web` for you when you are not logged in.
- Everything else passes straight through to `balena`, with device names resolved
  in the obvious slots (`device <sub> <device>`, `--device <device>`).

Before each command it prints the raw balena command it is about to run, so it
is a way to learn the CLI rather than hide it. `-q` / `--quiet` drops that for
one command, and `BALENA_PLUS_QUIET=1` for good.

## Install

Three routes, in order of preference. They all end in the same place: a
`balena-plus` on your PATH, plus the shell line at the bottom of this section.

On Windows, skip to [Windows](#windows) — it has its own installer and does
not use nix.

### With nix

```bash
nix profile install github:rileytuttle-havoc/balena-plus   # or
nix run github:rileytuttle-havoc/balena-plus -- devices    # one-off, installs nothing
```

This is the one to prefer: it pins the dependency versions, so the tool behaves
the same on every machine. Updates are `nix profile upgrade balena-plus`. The
wrapper checks once a day whether this repo has moved on and prints a one-line
nudge when it has; `BALENA_PLUS_NO_UPDATE_CHECK=1` turns that off.

### With the install script

If you do not have nix, this offers to set it up for you and then does the
above:

```bash
curl -fsSL https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/install.sh | bash
```

It explains what it is about to do and asks before each step (`y`, `N`, or `Y`
for yes-to-all). As always with `curl | bash`, read it first if you would rather:
it is [one file](install.sh).

**It will not install a second balena CLI.** balena-plus wraps whatever `balena`
is already on your PATH. If you do not have one it offers to bring one along;
if you do, it leaves it alone.

### Without nix

The fallback, if you would rather not have nix at all: answer no when the
installer asks, or pass `--no-nix`. It copies the script to `~/.local/bin` and
uses whatever `python3` and `fzf` you have. You lose pinned dependency versions
and the update check; everything else works the same.

### Then, however you installed it

Add this to your `~/.bashrc`. Nothing here edits your shell rc for you:

```bash
eval "$(balena-plus shell-init bash)"
```

That aliases `balena` to the wrapper and turns on tab completion for device and
fleet names. `\balena` still reaches the raw CLI. Open a new shell and try
`balena devices`.

## Windows

There is a PowerShell port in [`windows/`](windows/) — same commands, same
output, its own implementation so that work on one cannot break the other.
It targets Windows PowerShell 5.1, which ships with Windows 10 and 11, so
there is nothing to install first.

```powershell
irm https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/windows/install.ps1 | iex
```

[`windows/README.md`](windows/README.md) covers it properly. The short
version of what differs: `balena-raw` instead of `\balena`, `Import-Module`
instead of `shell-init`, `balena devices` emits objects you can pipe, and
there is no python3 dependency.

## Requirements

For the bash version. The Windows port needs only PowerShell 5.1 and `balena` —
see [`windows/README.md`](windows/README.md).

| | |
|---|---|
| `balena` | **required** — yours, not one this ships |
| `python3` | **required** — JSON wrangling |
| `fzf` | optional — without it the fleet picker is a numbered menu, and `BALENA_PLUS_PICKER=select` forces that anyway |
| `git` | optional — only for the daily update check |

A nix install pins `python3` and `fzf` (~220 MB) and leaves `balena` to you.

## Hacking

```bash
nix build .#balena-plus     # shellcheck runs as part of the build
nix flake check             # builds both packages
./result/bin/balena-plus --help
```

`balena-plus.sh` expects two variables from a generated preamble —
`plus_completion` and `self_rev`. `flake.nix` injects them for a nix build and
`install.sh` writes the same two lines for a no-nix install, so there is one
mechanism rather than two. Running the script straight out of a checkout works
too: both fall back to sensible defaults.

Widening platform support is the `systems` list at the top of `flake.nix`.

The Windows port is independent of all of the above — no nix, no flake. It
has a test suite, which the bash side does not:

```powershell
powershell -NoProfile -File windows\tests\BalenaPlus.Tests.ps1
Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows\PSScriptAnalyzerSettings.psd1
```

Both of those run from Linux as well — `nix shell nixpkgs#powershell` is
enough for the suite, and the analyzer settings check the source against a
captured Windows PowerShell 5.1 profile. [`windows/README.md`](windows/README.md#testing-it-without-a-windows-machine)
has the rest of the ladder, up to a real 5.1.
