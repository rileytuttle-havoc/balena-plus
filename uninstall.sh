#!/usr/bin/env bash
# Uninstall balena-plus -- the counterpart to install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/rileytuttle-havoc/balena-plus/main/uninstall.sh | bash
#
# Asks before it removes anything, and shows you each path first. Safe to
# re-run, and safe to run when only one of the two install routes was used:
# whatever is not there is reported and skipped.
#
# It does not edit your shell rc, for the same reason install.sh does not --
# that file is yours. It does tell you which line to take out, and where.
#
#   --yes     answer yes to every prompt (non-interactive)
#   --help    this text

set -euo pipefail

nix_flags=(--extra-experimental-features 'nix-command flakes')
bin_dir="$HOME/.local/bin"
share_dir="$HOME/.local/share/balena-plus"
# Generated state, not installed files: the device-name and completion caches
# and the ssh keepalive shim (an executable named ssh, which balena-plus puts
# on the PATH of the balena it runs -- see use_ssh_keepalive in balena-plus.sh).
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/balena-plus"

assume_yes=0

bold="" reset=""
if [ -t 1 ]; then
    bold=$'\e[1m' reset=$'\e[0m'
fi

info() { printf '%s\n' "$*"; }
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
        --help | -h) usage; exit 0 ;;
        *) die "unknown option '$1' (try --help)" ;;
    esac
done

heading "Uninstall balena-plus"
cat <<EOF
This removes the wrapper. It does not touch the balena CLI itself, which was
never installed by balena-plus and is yours.
EOF

removed=0

# ------------------------------------------------------------------ the nix route

heading "nix profile"
if ! command -v nix >/dev/null 2>&1; then
    info "No nix on PATH; nothing to remove there."
elif ! nix "${nix_flags[@]}" profile list 2>/dev/null | grep -q 'balena-plus'; then
    info "nix is installed, but balena-plus is not in your profile."
else
    info "Found balena-plus in your nix profile."
    if ask "Run 'nix profile remove' for it?"; then
        # --regex because the entry name depends on how it was installed:
        # a flake ref, an index, or a store path, none of which are stable.
        nix "${nix_flags[@]}" profile remove --regex '.*balena-plus.*'
        info "  removed"
        removed=1
    else
        info "  left in place"
    fi
fi

# ----------------------------------------------------------------- the copy route

heading "Copied files and cached state"
copy_paths=()
[ -e "$bin_dir/balena-plus" ] && copy_paths+=("$bin_dir/balena-plus")
[ -e "$share_dir" ] && copy_paths+=("$share_dir")
[ -e "$cache_dir" ] && copy_paths+=("$cache_dir")

if [ "${#copy_paths[@]}" -eq 0 ]; then
    info "Nothing at $bin_dir/balena-plus, $share_dir or $cache_dir."
else
    info "These would be deleted:"
    for p in "${copy_paths[@]}"; do
        printf '  %s\n' "$p"
    done
    if ask "Delete them?"; then
        for p in "${copy_paths[@]}"; do
            rm -rf -- "$p"
            printf '  removed %s\n' "$p"
        done
        removed=1
    else
        info "  left in place"
    fi
fi

# ------------------------------------------------------------------- your shell rc

heading "Your shell rc"
info "install.sh never edited this for you, so this will not either. If you"
info "added the line yourself, take it out:"
info ""
info "    eval \"\$(balena-plus shell-init bash)\""
info ""
found_rc=0
for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zshrc"; do
    if [ -f "$rc" ] && grep -q 'balena-plus shell-init' "$rc" 2>/dev/null; then
        printf '  found in %s (line %s)\n' "$rc" "$(grep -n 'balena-plus shell-init' "$rc" | cut -d: -f1 | paste -sd, -)"
        found_rc=1
    fi
done
[ "$found_rc" = 0 ] && info "  not found in .bashrc, .bash_profile, .profile or .zshrc."

heading "Done."
if [ "$removed" = 0 ]; then
    info "Nothing was removed."
else
    info "Open a new shell; 'balena' should be the raw CLI again."
fi
exit 0
