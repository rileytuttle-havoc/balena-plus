#!/usr/bin/env bash
# Install balena-plus -- a thin wrapper around the balena CLI that resolves
# device names, picks devices out of a fleet with fzf, and adds ssh/tunnel/
# logs/ps helpers.
#
#   curl -fsSL https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/install.sh | bash
#
# Asks before it does anything. Safe to re-run: it upgrades an existing install
# rather than duplicating it, and it never edits your shell rc for you.
#
#   --yes     answer yes to every prompt (non-interactive)
#   --no-nix  skip nix entirely; copy the script into ~/.local/bin
#   --help    this text

set -euo pipefail

raw_url="https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main"
flake_ref="github:rileytuttle-havoc/balena-plus"
nix_flags=(--extra-experimental-features 'nix-command flakes')

assume_yes=0
force_no_nix=0

bold="" dim="" reset=""
if [ -t 1 ]; then
    bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'
fi

info() { printf '%s\n' "$*"; }
warn() { printf '%sWarning: %s%s\n' "$dim" "$*" "$reset" >&2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
heading() { printf '\n%s%s%s\n' "$bold" "$*" "$reset"; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; /^set -euo/d'
}

# Prompts are read from /dev/tty, not stdin: under `curl ... | bash` stdin IS
# this script, and a bare `read` would eat the rest of it.
ask() {
    [ "$assume_yes" = 1 ] && return 0
    if [ ! -t 0 ] && [ ! -e /dev/tty ]; then
        die "no terminal to ask for confirmation; re-run with --yes"
    fi
    local reply
    printf '%s [y / N / Y = yes to all] ' "$1" >/dev/tty
    read -r reply </dev/tty || reply=""
    case "$reply" in
        Y) assume_yes=1; return 0 ;;
        y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes | -y) assume_yes=1; shift ;;
        --no-nix) force_no_nix=1; shift ;;
        --help | -h) usage; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

# ---------------------------------------------------------------- what we need

heading "balena-plus"
cat <<EOF
A wrapper around the balena CLI. It lets you say 'balena ssh foo-device'
instead of pasting a UUID, picks a device out of a fleet with fzf, and adds
tunnel/logs/ps helpers. The balena CLI itself does the real work.
EOF

have_balena=0
command -v balena >/dev/null 2>&1 && have_balena=1
if [ "$have_balena" = 1 ]; then
    info ""
    info "Found balena-cli at $(command -v balena) -- this will use it as-is,"
    info "and will not install a second copy."
else
    warn "No balena-cli found on your PATH."
fi

# --------------------------------------------------------------- the nix route

install_with_nix() {
    local attr="balena-plus"
    [ "$have_balena" = 1 ] || attr="balena-plus-with-cli"

    if ! command -v nix >/dev/null 2>&1; then
        heading "This installs using nix. What that means:"
        cat <<EOF
Nix is a package manager. Unlike apt or npm it puts everything under a single
directory, /nix, and changes nothing else on your system -- no system
libraries replaced, no interference with apt, npm, pip or your existing
balena-cli. It is what pins balena-plus to exact, tested versions of its
dependencies (python3 and fzf) so it behaves the same on every machine.

  - It needs sudo once, to create /nix and a background build daemon.
  - It downloads roughly 220 MB.
  - It is removable: '/nix/nix-installer uninstall' puts things back.
  - Installer used: https://install.determinate.systems/nix

If you would rather not, answer no and this falls back to copying the script
into ~/.local/bin, using whatever python3 and fzf you already have.
EOF
        ask "Install nix?" || return 1
        curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix |
            sh -s -- install --no-confirm ||
            die "the nix installer failed; re-run with --no-nix to install without it"

        # The installer adds this to login shells, but this shell predates it.
        # shellcheck disable=SC1091
        [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] &&
            . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        command -v nix >/dev/null 2>&1 ||
            die "nix installed but is not on this shell's PATH; open a new shell and re-run"
    else
        info ""
        info "Found nix at $(command -v nix)."
    fi

    # --extra-experimental-features on the command line rather than editing
    # anyone's nix.conf: works whether nix was just installed or predates flakes.
    if [ "$attr" = "balena-plus-with-cli" ]; then
        ask "Install balena-plus AND balena-cli (~610 MB, since you have no balena-cli)?" || return 1
    else
        ask "Install balena-plus from $flake_ref (~220 MB)?" || return 1
    fi

    heading "Installing..."
    # `nix profile install` fails on an existing install; upgrade that instead.
    if nix "${nix_flags[@]}" profile list 2>/dev/null | grep -q 'balena-plus'; then
        info "Already installed -- upgrading."
        nix "${nix_flags[@]}" profile upgrade --regex '.*balena-plus.*'
    else
        nix "${nix_flags[@]}" profile install "${flake_ref}#${attr}"
    fi
    installed_via="nix"
}

# ------------------------------------------------------- the copy-in-place route

install_without_nix() {
    heading "Installing without nix"
    local bin_dir="$HOME/.local/bin" share_dir="$HOME/.local/share/balena-plus"
    cat <<EOF
This copies the script to $bin_dir and its completion to
$share_dir. Nothing is pinned, and you supply the
dependencies yourself.
EOF
    local missing=()
    command -v balena >/dev/null 2>&1 || missing+=("balena-cli  (npm install -g balena-cli)")
    command -v python3 >/dev/null 2>&1 || missing+=("python3     (your package manager)")
    if [ "${#missing[@]}" -gt 0 ]; then
        warn "These are required and not on your PATH; this install will not work until they are:"
        printf '    %s\n' "${missing[@]}" >&2
    fi
    command -v fzf >/dev/null 2>&1 ||
        info "Note: no fzf -- the fleet picker falls back to a numbered menu."

    ask "Copy balena-plus into $bin_dir?" || return 1

    mkdir -p "$bin_dir" "$share_dir"
    local src="${BASH_SOURCE[0]%/*}"
    if [ -r "$src/balena-plus.sh" ] && [ -r "$src/completion.bash" ]; then
        cp "$src/completion.bash" "$share_dir/completion.bash"
        # Same generated preamble nix writes, so one mechanism serves both.
        # self_rev=unknown disables the update check: nothing to upgrade to.
        {
            printf '#!/usr/bin/env bash\n'
            printf '# Generated preamble -- install.sh injects these.\n'
            printf 'plus_completion=%s\n' "$share_dir/completion.bash"
            printf 'self_rev=unknown\n'
            cat "$src/balena-plus.sh"
        } >"$bin_dir/balena-plus"
    else
        curl -fsSL "$raw_url/completion.bash" -o "$share_dir/completion.bash" ||
            die "could not download completion.bash from $raw_url"
        {
            printf '#!/usr/bin/env bash\n'
            printf '# Generated preamble -- install.sh injects these.\n'
            printf 'plus_completion=%s\n' "$share_dir/completion.bash"
            printf 'self_rev=unknown\n'
            curl -fsSL "$raw_url/balena-plus.sh"
        } >"$bin_dir/balena-plus" || die "could not download balena-plus.sh from $raw_url"
    fi
    chmod +x "$bin_dir/balena-plus"

    case ":$PATH:" in
        *":$bin_dir:"*) ;;
        *) warn "$bin_dir is not on your PATH -- add it to use 'balena-plus'." ;;
    esac
    installed_via="copy"
}

# ----------------------------------------------------------------------- run it

installed_via=""
if [ "$force_no_nix" = 1 ]; then
    install_without_nix || die "cancelled."
else
    install_with_nix || {
        info ""
        if ask "Fall back to installing without nix?"; then
            install_without_nix || die "cancelled."
        else
            die "cancelled."
        fi
    }
fi

heading "Done."
cat <<'EOF'
One more step, which is yours to make -- add this to your ~/.bashrc:

    eval "$(balena-plus shell-init bash)"

That aliases `balena` to the wrapper (`\balena` still reaches the raw CLI) and
turns on tab completion for device and fleet names. Then open a new shell and:

    balena devices
    balena ssh <device-or-fleet>
EOF
if [ "$installed_via" = "copy" ]; then
    info ""
    info "Installed without nix, so nothing is version-pinned and there are no"
    info "update notifications. Re-run this installer to update."
fi
exit 0
