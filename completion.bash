# shellcheck shell=bash
# Bash completion for the `balena` alias (balena-plus). Sourced by
# `balena-plus shell-init bash` after balena-cli's own oclif-generated
# completion, which supplies _balena_autocomplete for everything not handled
# here.
#
# That oclif file is generated at runtime from whatever balena-cli is on PATH
# (see refresh_oclif_completion), so unlike when it was built by nix it can
# legitimately be absent -- no balena installed yet, or the generation failed.
# Stand in a no-op so the wrapper's own completions still work in that case.
declare -F _balena_autocomplete >/dev/null || _balena_autocomplete() { :; }
#
# Adds on top of oclif's completion:
#   - the wrapper's own commands (ssh, tunnel, logs, ps, uuid, devices) at the
#     top level
#   - device names for: ssh/tunnel/logs/ps/uuid <device>, device <sub> <device>,
#     and --device <device>
# Device names come from `balena-plus __complete-devices`, which caches them
# for 10 minutes, so the first tab after that may take a few seconds.

_balena_plus_devices() {
    local IFS=$'\n'
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$(balena-plus __complete-devices)" -- "$1"))
}

_balena_plus_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD - 1]}"
    # A leading -v/--verbose or -q/--quiet shifts every word position by one
    local off=0
    if [ "$COMP_CWORD" -gt 1 ]; then
        case "${COMP_WORDS[1]}" in
            -v | --verbose | -q | --quiet) off=1 ;;
        esac
    fi
    local cmd="${COMP_WORDS[1 + off]:-}"

    if [ "$prev" = "--device" ]; then
        _balena_plus_devices "$cur"
        return
    fi

    if [ "$COMP_CWORD" -eq $((1 + off)) ]; then
        _balena_autocomplete
        # shellcheck disable=SC2207
        COMPREPLY+=($(compgen -W "ssh tunnel logs ps uuid devices" -- "$cur"))
        return
    fi

    case "$cmd" in
        ssh|tunnel|logs|ps|uuid)
            if [ "$COMP_CWORD" -eq $((2 + off)) ]; then
                _balena_plus_devices "$cur"
            fi
            return
            ;;
        devices)
            return
            ;;
        device)
            # Same slot cmd_passthrough resolves: device <sub> <device>,
            # except list/register, which take a fleet.
            if [ "$COMP_CWORD" -eq $((3 + off)) ] && [[ "$cur" != -* ]] \
                && [[ "${COMP_WORDS[2 + off]}" != list && "${COMP_WORDS[2 + off]}" != register ]]; then
                _balena_plus_devices "$cur"
                return
            fi
            ;;
    esac

    _balena_autocomplete
}

complete -F _balena_plus_complete balena
