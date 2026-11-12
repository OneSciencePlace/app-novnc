# supervise.sh - the session supervisor for interactive apps that are several
# processes (an X server, a desktop, websockify, the gate...). SOURCE it from a
# bash entrypoint, after web/session-env.sh:
#
#     . /app/web/session-env.sh
#     . /app/web/supervise.sh
#
#     osp_spawn critical Xvnc   Xvnc       -- Xvnc :1 ...   # first = stopped last
#     osp_spawn leader   wm     fluxbox    -- fluxbox       # clean exit = log out
#     osp_spawn helper   xterm  xterm      -- xterm
#     osp_spawn critical gate   nginx      -- /app/web/token-gate.sh
#     osp_supervise                                          # never returns
#
# Single-program apps do not need this: they `exec` their program, which then
# receives signals directly.
#
# What it guarantees:
#
#   * Every service runs in its own process group (setsid), so stopping it
#     stops everything it started too -- a terminal's shell, a desktop's panel.
#   * Each launch is checked: the recorded pid must lead its own process group
#     and be running the expected program, not a wrapper that has already
#     handed off and exited.
#   * The session ends as soon as any `critical` or `leader` service exits,
#     including one that died before supervision began: each round first
#     checks that every watched service is alive, then `wait -n` sleeps until
#     a child exits (a SIGCHLD trap also wakes it). Nothing polls on a timer.
#     A `leader` exiting with status 0 is a normal log-out (exit 0); anything
#     else exits 1.
#   * Cleanup runs on every exit path (EXIT trap, installed here, before the
#     first service starts): TERM to every group in reverse start order, the
#     first-registered service (the X server) last so applications are not
#     cut off mid-save, then KILL whatever is left.
#   * Service output goes to the entrypoint's stderr, one "[name] " prefix per
#     line, so Tapis captures it with the job and nothing is written to disk.
#
# Requires bash >= 5.1 (wait -n -p). Ubuntu 26.04 ships 5.2 or newer.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "[supervise] web/supervise.sh must be sourced from bash" >&2
    exit 1
fi
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
    echo "[supervise] needs bash >= 5.1 for 'wait -n -p'; this is $BASH_VERSION" >&2
    exit 1
fi

_osp_order=()          # every registered pid, in start order
_osp_watch=()          # critical + leader pids: any exit ends the session
_osp_leader=""         # the one whose clean exit is a log-out
declare -A _osp_name=()

osp_log() { printf '[supervise] %s\n' "$*" >&2; }

# Is this pid running? kill -0 succeeds on a zombie (exited, not yet reaped),
# so read the state from /proc instead. Does not reap; wait does that.
osp_alive() {
    local st rest
    [ -n "${1:-}" ] || return 1
    read -r st 2>/dev/null < "/proc/$1/stat" || return 1
    rest=${st##*) }
    [ "${rest%% *}" != Z ]
}

# Fields 5 (pgrp) and 2 (comm) of /proc/<pid>/stat, without forking.
_osp_pgrp() {
    local st rest
    read -r st 2>/dev/null < "/proc/$1/stat" || return 1
    rest=${st##*) }
    # shellcheck disable=SC2206  # numeric fields: splitting is the point
    local -a f=($rest)
    printf '%s' "${f[2]}"
}
_osp_comm() {
    local c
    read -r c 2>/dev/null < "/proc/$1/comm" || return 1
    printf '%s' "$c"
}

# osp_start NAME -- COMMAND [ARGS...]
# Start COMMAND in its own session and process group, stdin from /dev/null,
# output relayed to our stderr with a "[NAME] " prefix. Sets OSP_PID.
osp_start() {
    local name=$1; shift
    [ "${1:-}" = "--" ] && shift
    case "$name" in ''|*[!A-Za-z0-9_.-]*) osp_log "bad service name '$name'"; return 1 ;; esac
    # In a non-interactive shell a background child is not a process-group
    # leader, so setsid calls setsid() and execs in place: $! is the service.
    setsid "$@" > >(sed -u "s/^/[$name] /" >&2) 2>&1 < /dev/null &
    OSP_PID=$!
}

# osp_register KIND NAME PID [COMM]
# KIND is critical, leader or helper. COMM, when given, is the program name the
# kernel reports (/proc/<pid>/comm, 15 characters at most) once the launch has
# settled; registration waits up to 5 s for it. A failed check is fatal for
# critical and leader services, a warning for helpers.
osp_register() {
    local kind=$1 name=$2 pid=$3 comm=${4:-} i got_pg got_comm
    for (( i = 0; i < 50; i++ )); do
        osp_alive "$pid" || break
        got_pg=$(_osp_pgrp "$pid") || break
        got_comm=$(_osp_comm "$pid") || break
        if [ "$got_pg" = "$pid" ] && { [ -z "$comm" ] || [ "$got_comm" = "$comm" ]; }; then
            _osp_order+=("$pid")
            _osp_name[$pid]=$name
            case "$kind" in
                critical) _osp_watch+=("$pid") ;;
                leader)   _osp_watch+=("$pid"); _osp_leader=$pid ;;
                helper)   ;;
                *) osp_log "unknown kind '$kind' for $name"; return 1 ;;
            esac
            return 0
        fi
        sleep 0.1
    done
    if osp_alive "$pid"; then
        osp_log "launch check failed for $name: pid $pid has pgrp ${got_pg:-?}, runs '${got_comm:-?}', expected own group running '${comm:-any}'"
        # Not ours to manage cleanly; make sure it does not outlive us.
        kill -TERM "$pid" 2>/dev/null || true
    else
        osp_log "$name (pid $pid) exited during startup"
    fi
    [ "$kind" = helper ] && return 0
    exit 1
}

# osp_spawn KIND NAME COMM -- COMMAND [ARGS...]   start + register
osp_spawn() {
    local kind=$1 name=$2 comm=$3; shift 3
    osp_start "$name" "$@"
    osp_register "$kind" "$name" "$OSP_PID" "$comm"
}

# Fill _osp_live with the process groups (among $@) that still have a running,
# non-zombie member. One pass over /proc per call.
_osp_scan() {
    local f st rest pg
    local -A want=()
    _osp_live=()
    for pg in "$@"; do want[$pg]=1; done
    for f in /proc/[0-9]*/stat; do
        read -r st 2>/dev/null < "$f" || continue
        rest=${st##*) }
        # shellcheck disable=SC2206  # numeric fields: splitting is the point
        local -a a=($rest)
        [ "${a[0]}" = Z ] && continue
        [ -n "${want[${a[2]}]:-}" ] && _osp_live[${a[2]}]=1
    done
    return 0
}
declare -A _osp_live=()

# TERM each group (in the order given), then wait up to $1 tenths of a second
# for all of them to be gone.
_osp_stop_groups() {
    local tenths=$1 pg i; shift
    [ "$#" -gt 0 ] || return 0
    for pg in "$@"; do kill -TERM -- "-$pg" 2>/dev/null || true; done
    for (( i = 0; i < tenths; i++ )); do
        _osp_scan "$@"
        [ "${#_osp_live[@]}" -eq 0 ] && return 0
        sleep 0.1
    done
}

_osp_cleanup() {
    local rc=$? i pg rest=()
    trap - EXIT INT TERM CHLD
    set +e
    if [ "${#_osp_order[@]}" -gt 0 ]; then
        # Everything but the first-registered service, newest first...
        for (( i = ${#_osp_order[@]} - 1; i >= 1; i-- )); do rest+=("${_osp_order[i]}"); done
        _osp_stop_groups 30 "${rest[@]}"
        # ...then the first one (the X server), so it is not pulled out from
        # under applications that are still writing their files.
        _osp_stop_groups 50 "${_osp_order[0]}"
        _osp_scan "${_osp_order[@]}"
        for pg in "${!_osp_live[@]}"; do
            osp_log "${_osp_name[$pg]:-group $pg} ignored TERM; killing it"
            kill -KILL -- "-$pg" 2>/dev/null
        done
        for pg in "${_osp_order[@]}"; do wait "$pg" 2>/dev/null; done
    fi
    # The session directory holds the rendered config (with the token), the X
    # cookie and the sockets. Under the run profile /tmp vanishes with the
    # container anyway; without it, do not leave them behind on the node.
    case "${OSP_APP_SOCK_DIR:-}" in
        /tmp/osp-app-*) rm -rf -- "$OSP_APP_SOCK_DIR" ;;
    esac
    osp_log "session ended"
    exit "$rc"
}
trap _osp_cleanup EXIT
trap 'osp_log "received SIGTERM"; exit 143' TERM
trap 'osp_log "received SIGINT"; exit 130' INT

# Block until a critical or leader service exits, then end the session. The
# EXIT trap does the stopping.
#
# `wait -n` alone is not enough. A service that exits after it is registered
# but before `wait -n` starts -- while the rest of the session is still
# starting -- has already been reaped and reported by bash, which then forgets
# it: `wait -n` answers "no such job" for that pid and waits on the others,
# and the session would run on without, say, its X server (plan S-8). So each
# round first checks every watched service with osp_alive (a reaped or zombie
# process is not alive) and only then waits. A trap on SIGCHLD makes any
# child's exit end the wait early, so a death between the check and the wait
# is caught on the next round rather than missed.
osp_supervise() {
    local pid="" rc=0 n names=() dead
    if [ "${#_osp_watch[@]}" -eq 0 ]; then
        osp_log "no critical services registered"
        exit 1
    fi
    for n in "${_osp_watch[@]}"; do names+=("${_osp_name[$n]}"); done
    osp_log "supervising: ${names[*]} (pid $$)"
    trap ':' CHLD
    while :; do
        dead=""
        for n in "${_osp_watch[@]}"; do
            osp_alive "$n" || { dead=$n; break; }
        done
        if [ -n "$dead" ]; then
            # bash keeps a reaped child's status for `wait <pid>`.
            pid=$dead
            if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
            break
        fi
        pid=""
        if wait -n -p pid "${_osp_watch[@]}" 2>/dev/null; then rc=0; else rc=$?; fi
        # A pid means a watched service ended. No pid: another child (a
        # helper, a log relay) woke the wait, or bash had already forgotten
        # the job; check again.
        [ -n "$pid" ] && break
    done
    trap - CHLD
    n=${_osp_name[$pid]:-"pid ${pid:-?}"}
    if [ "$rc" -eq 0 ] && [ -n "$pid" ] && [ "$pid" = "$_osp_leader" ]; then
        osp_log "$n exited normally; ending the session"
        exit 0
    fi
    osp_log "$n exited (status $rc); ending the session"
    exit 1
}
