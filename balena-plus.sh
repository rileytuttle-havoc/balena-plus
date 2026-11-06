# shellcheck shell=bash
# Thin wrapper around the balena CLI. flake.nix packages this as `balena-plus`
# (with python3 and fzf on its PATH) and `balena-plus shell-init bash` aliases
# it to `balena`; `\balena` still reaches the raw CLI. Usage text is in usage().
#
# The balena CLI itself is deliberately NOT baked into the package: the wrapper
# uses whatever `balena` is already on your PATH, so installing this does not
# land a second ~630MB copy on a machine that has one. ensure_login says so
# plainly if there isn't one.
#
# Two variables are expected from a generated preamble prepended to this file
# (see flake.nix, and the no-nix branch of install.sh). Both have fallbacks so
# the script still runs when it is executed straight out of a checkout.

set -euo pipefail

# Set by the generated preamble; the defaults are the run-from-a-checkout case.
plus_completion="${plus_completion:-}"
self_rev="${self_rev:-unknown}"
upstream_url="${upstream_url:-https://github.com/rileytuttle/balena-plus}"

prog="balena"
device_list_json=""
verbose="${BALENA_PLUS_VERBOSE:-0}"
dim="" reset=""
if [ -t 2 ]; then
    dim=$'\e[2m' reset=$'\e[0m'
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/balena-plus"
# balena-cli shows no bash completion of its own, but its oclif autocomplete
# plugin generates one on demand. Done here at runtime rather than at build
# time so that packaging this needs no balena-cli in the closure.
oclif_cache="$cache_dir/balena-oclif.bash"
update_stamp="$cache_dir/update-check"

usage() {
    cat <<'EOF'
Usage: balena [-v|--verbose] <command> [args...]

Thin wrapper around the balena CLI that:
  - runs 'balena login --web' automatically if not logged in
  - accepts device names (exact, or a unique substring) anywhere
    a device UUID is expected; a fleet name brings up an fzf device
    picker (BALENA_PLUS_PICKER=select for a plain numbered menu)
  - adds a few convenience commands (logs, ps, uuid, devices, tunnel)

  -v, --verbose   Print the equivalent raw balena commands to stderr
                  (also BALENA_PLUS_VERBOSE=1). A bare 'balena -v' still
                  prints the CLI version.

Commands:
  ssh <device> [service]            SSH into the host OS (or a service container)
  tunnel <device> <port...>         Tunnel device ports to localhost. A port is
                                    <remote>[:[localIP:]local]; the -p the raw
                                    CLI wants is optional. Repeat for more ports.
  logs <device> <container> [opts]  Container logs via the host's balena engine
                                    opts: -f, -n/--tail N, -t, or any 'balena logs' flag
  ps <device> [ps opts]             'balena ps' on the device host
  uuid <device>                     Print the full UUID for a device name
  devices [filter]                  List devices (name, uuid, status, fleet)
  shell-init bash                   Print shell glue (the 'balena' alias plus
                                    tab completion) for your ~/.bashrc:
                                      eval "$(balena-plus shell-init bash)"
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
  balena -v logs foo-device bar-app -f    (show the raw commands too)

The raw CLI (and its own help) is still at '\balena', e.g. '\balena help'.
It is whatever balena-cli is on your PATH -- this wrapper does not ship one.

BALENA_PLUS_NO_UPDATE_CHECK=1 silences the once-a-day "update available" line.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# In verbose mode, print a raw balena command you could type by hand
show() {
    if [ "$verbose" = 1 ]; then
        printf '%s+ %s%s\n' "$dim" "$*" "$reset" >&2
    fi
}

ensure_login() {
    command -v balena >/dev/null || die "balena CLI not found in PATH.
  balena-plus wraps your own balena-cli rather than shipping one, so that
  installing it does not duplicate a CLI you already have. Install it with
  'npm install -g balena-cli', or from
  https://github.com/balena-io/balena-cli/blob/master/INSTALL.md"
    if ! balena whoami >/dev/null 2>&1; then
        echo "Not logged in to balena, starting web login..." >&2
        show "balena login --web"
        balena login --web
    fi
}

device_list() {
    if [ -z "$device_list_json" ]; then
        device_list_json="$(balena device list --json)"
        echo "$device_list_json" | write_names_cache || true
    fi
    echo "$device_list_json"
}

# Device names for tab completion, one per line. Refreshed whenever the
# device list is fetched, so ordinary use keeps it warm.
names_cache="$cache_dir/device-names"

write_names_cache() {
    mkdir -p "$(dirname "$names_cache")"
    python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if d.get("device_name"):
        print(d["device_name"])
' >"$names_cache.tmp" && mv "$names_cache.tmp" "$names_cache"
}

# Called by the bash completion: print device names, refetching if the cache
# is missing or over 10 minutes old. Never prompts for login; prints nothing
# if the fetch fails.
cmd_complete_devices() {
    if [ -z "$(find "$names_cache" -mmin -10 2>/dev/null)" ]; then
        balena device list --json 2>/dev/null | write_names_cache 2>/dev/null || true
    fi
    cat "$names_cache" 2>/dev/null || true
}

# Generate balena-cli's own bash completion into the cache. HOME and
# XDG_CACHE_HOME point at a tempdir so this needs no login and leaves the real
# balena-cli cache alone; only the generated file is kept. Returns non-zero
# (quietly) if there is no balena to ask, which just means completion falls
# back to ours alone.
refresh_oclif_completion() {
    local tmp
    command -v balena >/dev/null || return 1
    tmp="$(mktemp -d)" || return 1
    if HOME="$tmp" XDG_CACHE_HOME="$tmp/cache" \
        balena autocomplete bash --refresh-cache >/dev/null 2>&1 &&
        [ -s "$tmp/cache/balena-cli/autocomplete/functions/bash/balena.bash" ]; then
        install -Dm644 "$tmp/cache/balena-cli/autocomplete/functions/bash/balena.bash" \
            "$oclif_cache"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

# Shell glue for ~/.bashrc: eval "$(balena-plus shell-init bash)". Generates
# balena-cli's completion on first use (a second or so), then it is cached.
cmd_shell_init() {
    local shell="${1:-bash}"
    [ "$shell" = bash ] || die "shell-init: only bash is supported, not '$shell'"

    # Regenerate when it is missing, and monthly after that so it cannot drift
    # too far from a balena-cli upgraded underneath it -- which is the one
    # thing generating at runtime gives up versus building it with the CLI.
    # Costs a couple of seconds; every other shell start reads the cache.
    # Deleting the file forces a refresh.
    if [ ! -s "$oclif_cache" ] || [ -z "$(find "$oclif_cache" -mtime -30 2>/dev/null)" ]; then
        refresh_oclif_completion || true
    fi

    echo 'alias balena=balena-plus'
    # oclif's first (it defines _balena_autocomplete), then ours, which takes
    # over `complete balena` and falls back to it.
    [ -s "$oclif_cache" ] && echo "source $oclif_cache"
    [ -n "$plus_completion" ] && echo "source $plus_completion"
    return 0
}

# The home-manager-news equivalent: say once a day when the flake has moved on.
# Deliberately unobtrusive -- never blocks, never fails a command, and says
# nothing at all if git is missing, the network is down, or this was not
# installed from a tagged revision (a checkout or the no-nix install).
check_for_update() {
    [ "${BALENA_PLUS_NO_UPDATE_CHECK:-0}" = 1 ] && return 0
    [ "$self_rev" = unknown ] && return 0
    # Stamp before asking, so a flaky network cannot retry on every command.
    [ -n "$(find "$update_stamp" -mtime -1 2>/dev/null)" ] && return 0
    mkdir -p "$cache_dir" && : >"$update_stamp" || return 0
    command -v git >/dev/null || return 0

    # GIT_TERMINAL_PROMPT=0 so a repo that has gone private asks nobody for a
    # password; timeout so a black-holed network costs 5s once a day, not a hang.
    local latest
    latest="$(GIT_TERMINAL_PROMPT=0 timeout 5 git ls-remote "$upstream_url" main 2>/dev/null | cut -f1)" || return 0
    if [ -n "$latest" ] && [ "$latest" != "$self_rev" ]; then
        printf '%sbalena-plus: an update is available -- nix profile upgrade balena-plus%s\n' \
            "$dim" "$reset" >&2
    fi
    return 0
}

# Match a device by name/UUID prefix ('exact') or name substring ('substring').
# Prints the UUID; exits 3 if nothing matched, 1 if ambiguous.
match_device() {
    local mode="$1" query="$2"
    device_list | python3 -c '
import json, sys
mode, query = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)

def pick(matches, kind):
    if len(matches) == 1:
        print(matches[0]["uuid"])
        sys.exit(0)
    if len(matches) > 1:
        names = ", ".join(sorted(d["device_name"] for d in matches))
        sys.exit(f"Error: {query!r} {kind} matches multiple devices: {names}")

if mode == "exact":
    pick([d for d in devices if d.get("device_name") == query], "name")
    pick([d for d in devices if d["uuid"].startswith(query.lower())], "uuid")
else:
    pick([d for d in devices if query.lower() in d.get("device_name", "").lower()], "substring")
sys.exit(3)
' "$mode" "$query"
}

# Match a fleet by name or slug (case-insensitive). Prints the slug; exits 3 if no match.
match_fleet() {
    local query="$1"
    balena fleet list --json | python3 -c '
import json, sys
query = sys.argv[1].lower()
for f in json.load(sys.stdin):
    if query in (f.get("app_name", "").lower(), f.get("slug", "").lower()):
        print(f.get("slug") or f["app_name"])
        sys.exit(0)
sys.exit(3)
' "$query"
}

# Interactively pick a device from a fleet (online devices first). Prints the
# UUID. Uses fzf when it's installed; falls back to bash's numbered 'select'
# menu, which BALENA_PLUS_PICKER=select also forces.
select_fleet_device() {
    local fleet="$1"
    local rows=()
    mapfile -t rows < <(balena device list --fleet "$fleet" --json | python3 -c '
import json, sys
devices = sorted(json.load(sys.stdin), key=lambda d: (not d.get("is_online"), d.get("device_name", "")))
for d in devices:
    uuid, name = d["uuid"], d.get("device_name", "")
    status = "online" if d.get("is_online") else "offline"
    print(f"{uuid}\t{name:<24} {uuid[:7]}  {status}")
')
    [ "${#rows[@]}" -gt 0 ] || die "fleet '$fleet' has no devices"
    if [ "${#rows[@]}" -eq 1 ]; then
        echo "Fleet '$fleet' has one device: ${rows[0]#*$'\t'}" >&2
        echo "${rows[0]%%$'\t'*}"
        return
    fi
    { : </dev/tty; } 2>/dev/null || die "fleet '$fleet' has multiple devices and no terminal to choose from"

    # fzf reads keys from and draws on /dev/tty, so it still works with our
    # stdout captured by the caller's command substitution. The UUID is field 1
    # and stays hidden (--with-nth=2), but comes back on the selected line.
    if [ "${BALENA_PLUS_PICKER:-}" != "select" ] && command -v fzf >/dev/null 2>&1; then
        local picked
        picked="$(printf '%s\n' "${rows[@]}" | fzf \
            --delimiter=$'\t' --with-nth=2 \
            --no-multi --height=40% --reverse \
            --prompt="$fleet> " \
            --header='select a device (type to filter, esc to cancel)')" \
            || die "no device selected"
        echo "${picked%%$'\t'*}"
        return
    fi

    local labels=("${rows[@]#*$'\t'}") choice
    echo "Select a device from fleet '$fleet':" >&2
    PS3="Device #: "
    select choice in "${labels[@]}"; do
        if [ -n "$choice" ]; then
            echo "${rows[REPLY - 1]%%$'\t'*}"
            return
        fi
    done </dev/tty
    die "no device selected"
}

# Resolve a device name, UUID or fleet name to a full device UUID.
# Order: exact device name / UUID prefix, fleet (interactive selector), name substring.
resolve_uuid() {
    local query="$1" uuid fleet rc=0
    uuid="$(match_device exact "$query")" || rc=$?
    case "$rc" in
        0)
            show "balena device list | grep $(printf '%q' "$query")   # -> $uuid"
            echo "$uuid"
            return
            ;;
        3) ;;
        *) exit "$rc" ;;
    esac

    rc=0
    fleet="$(match_fleet "$query")" || rc=$?
    if [ "$rc" -eq 0 ]; then
        uuid="$(select_fleet_device "$fleet")"
        show "balena device list --fleet $(printf '%q' "$fleet")   # picked -> $uuid"
        echo "$uuid"
        return
    fi

    rc=0
    uuid="$(match_device substring "$query")" || rc=$?
    case "$rc" in
        0)
            show "balena device list | grep -i $(printf '%q' "$query")   # -> $uuid"
            echo "$uuid"
            ;;
        3) die "no device or fleet matching '$query'" ;;
        *) exit "$rc" ;;
    esac
}

# Run a shell script on the device host OS (commands are piped over 'balena device ssh')
host_exec() {
    local uuid="$1" script="$2"
    printf '%s\nexit\n' "$script" | balena device ssh "$uuid"
}

cmd_ssh() {
    [ "$#" -ge 1 ] || die "usage: $prog ssh <device> [service]"
    local uuid
    uuid="$(resolve_uuid "$1")"
    shift
    show "balena device ssh $uuid${*+ $(printf '%q ' "$@")}"
    exec balena device ssh "$uuid" "$@"
}

# 'balena device tunnel', but the -p before each port mapping is optional: a
# bare '8080:3000' (or '8080') gets one added. An explicit -p/--port still
# works, so anything the raw CLI accepts is accepted here too.
cmd_tunnel() {
    [ "$#" -ge 1 ] || die "usage: $prog tunnel <device> <remote>[:[localIP:]local] ..."
    local uuid
    uuid="$(resolve_uuid "$1")"
    shift
    [ "$#" -ge 1 ] || die "usage: $prog tunnel <device> <remote>[:[localIP:]local] ..."

    local args=() arg prev=""
    for arg in "$@"; do
        if [[ "$prev" != -p && "$prev" != --port && "$arg" =~ ^[0-9]+(:[^:]*)*$ ]]; then
            args+=(-p "$arg")
        else
            args+=("$arg")
        fi
        prev="$arg"
    done

    show "balena device tunnel $uuid $(printf '%q ' "${args[@]}")"
    exec balena device tunnel "$uuid" "${args[@]}"
}

cmd_logs() {
    [ "$#" -ge 2 ] || die "usage: $prog logs <device> <container> [-f] [-n N] [-t]"
    local uuid container
    uuid="$(resolve_uuid "$1")"
    container="$2"
    shift 2

    local log_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n) log_args+=(--tail "$2"); shift 2 ;;
            *)  log_args+=("$1"); shift ;;
        esac
    done

    # Pick the single running container whose name contains $container
    local script
    script="$(cat <<EOF
matches=\$(balena ps --format '{{.ID}} {{.Names}}' | grep -- $(printf '%q' "$container"))
count=\$(printf '%s\n' "\$matches" | grep -c .)
if [ "\$count" -ne 1 ]; then
    echo "Error: expected 1 container matching $(printf '%q' "$container"), found \$count:" >&2
    [ "\$count" -gt 0 ] && printf '%s\n' "\$matches" >&2
    balena ps --format '  {{.Names}}' >&2
    exit 1
fi
exec balena logs ${log_args[*]+$(printf '%q ' "${log_args[@]}")}\${matches%% *}
EOF
)"
    show "balena device ssh $uuid"
    show "  (on host) balena ps | grep $(printf '%q' "$container")"
    show "  (on host) balena logs ${log_args[*]+$(printf '%q ' "${log_args[@]}")}<container-id>"
    host_exec "$uuid" "$script"
}

cmd_ps() {
    [ "$#" -ge 1 ] || die "usage: $prog ps <device> [ps opts]"
    local uuid
    uuid="$(resolve_uuid "$1")"
    shift
    show "balena device ssh $uuid"
    show "  (on host) balena ps ${*+$(printf '%q ' "$@")}"
    host_exec "$uuid" "balena ps ${*+$(printf '%q ' "$@")}"
}

cmd_uuid() {
    [ "$#" -eq 1 ] || die "usage: $prog uuid <device>"
    resolve_uuid "$1"
}

cmd_devices() {
    show "balena device list"
    device_list | python3 -c '
import json, sys
query = sys.argv[1].lower() if len(sys.argv) > 1 else ""
rows = []
for d in json.load(sys.stdin):
    name = d.get("device_name", "")
    if query and query not in name.lower():
        continue
    fleet = d.get("fleet") or d.get("belongs_to__application") or ""
    if isinstance(fleet, list):
        fleet = fleet[0] if fleet else ""
    if isinstance(fleet, dict):
        fleet = fleet.get("app_name") or fleet.get("slug") or ""
    status = "online" if d.get("is_online") else "offline"
    rows.append((name, d["uuid"][:7], status, str(fleet)))
rows.sort()
w = [max([len(h)] + [len(r[i]) for r in rows]) for i, h in enumerate(("NAME", "UUID", "STATUS", "FLEET"))]
for r in [("NAME", "UUID", "STATUS", "FLEET")] + rows:
    print("  ".join(c.ljust(w[i]) for i, c in enumerate(r)).rstrip())
' "$@"
}

# Pass through to balena, resolving device names in the obvious device slots
cmd_passthrough() {
    local args=("$@")
    local i
    # 'device list/register' take a fleet, not a device
    if [ "${args[0]:-}" = "device" ] && [ "${#args[@]}" -ge 3 ] && [[ "${args[2]}" != -* ]] \
        && [[ "${args[1]}" != list && "${args[1]}" != register ]]; then
        args[2]="$(resolve_uuid "${args[2]}")"
    fi
    for ((i = 0; i < ${#args[@]} - 1; i++)); do
        if [ "${args[i]}" = "--device" ]; then
            args[i + 1]="$(resolve_uuid "${args[i + 1]}")"
        fi
    done
    show "balena $(printf '%q ' "${args[@]}")"
    exec balena "${args[@]}"
}

# Leading -v/--verbose turns on verbose mode; a bare 'balena -v' falls
# through to the CLI's own version flag
if [ "$#" -ge 2 ] && { [ "$1" = "-v" ] || [ "$1" = "--verbose" ]; }; then
    verbose=1
    shift
fi

if [ "$#" -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
    usage
    exit 0
fi

# Both of these run before ensure_login: neither needs an account, and glue
# that a shell evaluates at startup must never open a browser for a web login.
if [ "$1" = "__complete-devices" ]; then
    cmd_complete_devices
    exit 0
fi

if [ "$1" = "shell-init" ]; then
    shift
    cmd_shell_init "$@"
    exit 0
fi

ensure_login
check_for_update

command="$1"
shift
case "$command" in
    ssh)     cmd_ssh "$@" ;;
    tunnel)  cmd_tunnel "$@" ;;
    logs)    cmd_logs "$@" ;;
    ps)      cmd_ps "$@" ;;
    uuid)    cmd_uuid "$@" ;;
    devices) cmd_devices "$@" ;;
    *)       cmd_passthrough "$command" "$@" ;;
esac
