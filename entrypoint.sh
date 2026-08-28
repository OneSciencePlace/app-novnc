#!/bin/sh
# app-novnc - branch B of the interactive contract: no native URL-token auth,
# so the nginx gate owns the single exposed port and everything else binds
# 127.0.0.1.
#
#   0.0.0.0:OSP_APP_PORT            nginx gate   <- the only thing off-node sees
#   127.0.0.1:OSP_APP_UPSTREAM_PORT websockify + noVNC static files
#   127.0.0.1:590<n>            Xvnc
set -eu

# Scratch directory. The scheduler usually hands us a TMPDIR pointing at a host
# path like /scratch/$USER/job.12345 -- and Apptainer binds $HOME, /tmp and $PWD
# by default, NOT necessarily /scratch. Inside the container that path does not
# exist and the root filesystem is read-only, so `mkdir -p "$TMPDIR"` dies with
# "cannot create directory '/scratch': Read-only file system". Try the
# candidates in order and use the first one we can actually write to. Bind the
# real scratch in (`--bind /scratch`) if you want it used.
_pick_tmpdir() {
    for _d in "${TMPDIR:-}" /tmp "${HOME:-}"; do
        [ -n "$_d" ] || continue
        mkdir -p "$_d" 2>/dev/null || continue
        [ -w "$_d" ] || continue
        printf '%s' "$_d"
        return 0
    done
    return 1
}
_tmpdir_was="${TMPDIR:-}"
TMPDIR="$(_pick_tmpdir)" || {
    echo "[app] no writable scratch directory (tried TMPDIR, /tmp, HOME)" >&2
    exit 1
}
export TMPDIR
if [ -n "$_tmpdir_was" ] && [ "$_tmpdir_was" != "$TMPDIR" ]; then
    echo "[app] TMPDIR=$_tmpdir_was is not writable in this container; using $TMPDIR" >&2
fi

. /app/web/session-env.sh

: "${OSP_APP_UPSTREAM_PORT:=$((OSP_APP_PORT + 1))}"
: "${VNC_GEOMETRY:=1920x1080}"
export OSP_APP_UPSTREAM_PORT

mkdir -p "${XDG_RUNTIME_DIR:-$TMPDIR/run}"

# X only creates /tmp/.X11-unix when it is running as root, which we never
# are. Under Docker the Dockerfile pre-creates it; under Apptainer /tmp is
# usually bind-mounted from the host and this is the line that matters.
mkdir -p /tmp/.X11-unix 2>/dev/null || true

# An MIT-MAGIC-COOKIE under /tmp. The X server has to authenticate its local
# clients somehow and we cannot write to the image or assume a usable HOME.
XAUTHORITY="$TMPDIR/Xauthority"
export XAUTHORITY
: > "$XAUTHORITY"
XAUTH_COOKIE="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"

XVNC_LOG="$TMPDIR/xvnc.log"

cleanup() { kill ${XVNC_PID:-} ${WM_PID:-} ${WS_PID:-} 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Try one display number. Returns 0 and sets VNC_DISPLAY/VNC_PORT on success.
#
# -SecurityTypes None and no VNC password are deliberate: Xvnc listens on
# localhost only, its sole client is websockify in this same container, and
# the browser-facing authentication is the token gate. A VNC password here
# would be a second secret protecting a socket nobody can reach.
try_display() {
    _d=":$1"
    _p=$((5900 + $1))
    xauth -f "$XAUTHORITY" add "$_d" . "$XAUTH_COOKIE" 2>/dev/null || return 1

    Xvnc "$_d" \
        -rfbport "$_p" \
        -localhost \
        -SecurityTypes None \
        -geometry "$VNC_GEOMETRY" \
        -depth 24 \
        -auth "$XAUTHORITY" \
        -AlwaysShared \
        -desktop "app-novnc" >>"$XVNC_LOG" 2>&1 &
    XVNC_PID=$!

    # Wait for the display to answer rather than sleeping and hoping. Bail out
    # early if Xvnc has already died -- that is the "display taken" case.
    _i=0
    while ! DISPLAY="$_d" xdpyinfo >/dev/null 2>&1; do
        kill -0 "$XVNC_PID" 2>/dev/null || return 1
        _i=$((_i + 1))
        [ "$_i" -lt 100 ] || return 1
        sleep 0.1
    done

    VNC_DISPLAY="$_d"
    VNC_PORT="$_p"
    return 0
}

# X display numbers are global to the node: the lock (/tmp/.X<n>-lock) and the
# socket (/tmp/.X11-unix/X<n>) live in a /tmp that Apptainer usually shares with
# every other user on it. Hardcoding :1 means the second session on a node dies
# with "Server is already active for display 1", so walk until one takes.
# Setting VNC_DISPLAY explicitly opts out and demands that exact number.
if [ -n "${VNC_DISPLAY:-}" ]; then
    try_display "${VNC_DISPLAY#:}" || {
        echo "[novnc] display ${VNC_DISPLAY} is not available:" >&2
        tail -5 "$XVNC_LOG" >&2
        exit 1
    }
else
    _n=1
    until try_display "$_n"; do
        _n=$((_n + 1))
        [ "$_n" -le 64 ] || {
            echo "[novnc] no free X display between :1 and :64" >&2
            tail -5 "$XVNC_LOG" >&2
            exit 1
        }
    done
fi

export DISPLAY="$VNC_DISPLAY"
echo "[novnc] Xvnc ready on $VNC_DISPLAY (rfb $VNC_PORT)"

# The desktop itself. Swap fluxbox for xfce4-session, or exec ParaView/VMD/
# whatever directly, to build a different app-* on this same skeleton.
fluxbox >"$TMPDIR/fluxbox.log" 2>&1 &
WM_PID=$!
xterm -geometry 100x30+80+60 >/dev/null 2>&1 &

# websockify serves the noVNC client AND bridges the websocket to Xvnc, all on
# loopback. Everything the browser fetches comes back through the gate.
websockify --web=/usr/share/novnc \
    "127.0.0.1:${OSP_APP_UPSTREAM_PORT}" "127.0.0.1:${VNC_PORT}" \
    >"$TMPDIR/websockify.log" 2>&1 &
WS_PID=$!

echo "[novnc] websockify on 127.0.0.1:${OSP_APP_UPSTREAM_PORT} -> 127.0.0.1:${VNC_PORT}"

exec /app/web/token-gate.sh
