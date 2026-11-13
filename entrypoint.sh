#!/bin/bash
# app-novnc - branch B of the interactive contract: no native URL-token auth,
# so the nginx gate owns the one TCP port and everything behind it is a Unix
# socket in the session's private directory.
#
#   $OSP_APP_BIND:$OSP_APP_PORT     nginx gate     <- the only TCP listener
#   $OSP_APP_SOCK_DIR/app.sock      websockify + noVNC static files
#   $OSP_APP_SOCK_DIR/vnc.sock      Xvnc (RFB); no TCP port, no abstract socket
#
# This app is five processes, so the entrypoint stays and supervises them
# (web/supervise.sh) rather than exec'ing any one of them. bash, not sh, for
# `wait -n`.
set -eu
umask 077

# Bulk scratch directory. The scheduler usually hands us a TMPDIR pointing at a
# host path like /scratch/$USER/job.12345 -- and Apptainer does not necessarily
# bind it. Inside the container that path may not exist and the root
# filesystem is read-only, so `mkdir -p "$TMPDIR"` would die with "Read-only
# file system". Try the candidates in order and use the first one we can
# actually write to. Under the OSP run profile the app definition sets
# TMPDIR=<job directory>/tmp, which is bound and writable.
#
# Only bulk data goes here. Secrets, sockets and session state go in
# $OSP_APP_SOCK_DIR (created by session-env.sh under the private /tmp).
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

. /app/web/session-env.sh       # OSP_APP_PORT, OSP_APP_BIND, OSP_APP_TOKEN*, OSP_APP_SOCK_DIR
. /app/web/supervise.sh         # installs the cleanup trap before anything starts

: "${VNC_GEOMETRY:=1920x1080}"
# What the gate's /healthz asks websockify for: noVNC's client page.
export OSP_APP_HEALTH_PATH="${OSP_APP_HEALTH_PATH:-vnc.html}"

VNC_SOCK="$OSP_APP_SOCK_DIR/vnc.sock"
APP_SOCK="$OSP_APP_SOCK_DIR/app.sock"

# dbus and friends put their sockets here; it belongs to this session only.
XDG_RUNTIME_DIR="$OSP_APP_SOCK_DIR/run"
mkdir -p "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR

# HOME and XDG_CACHE_HOME: web/session-env.sh has already moved them off the
# image's /tmp defaults, per session.

# Every service below starts without OSP_APP_TOKEN in its environment
# (env -u): only the gate needs it, so the desktop, its terminal and anything
# the user runs never hold it.

# X only creates /tmp/.X11-unix when it is running as root, which we never
# are. Under Docker the Dockerfile pre-creates it; under Apptainer /tmp is the
# session's own (with the run profile) or the node's (without), and this is
# the line that matters. 1777 explicitly: umask 077 would otherwise make it
# 0700, and on a node-shared /tmp that would lock every other user's X server
# out of it.
[ -d /tmp/.X11-unix ] || mkdir -m 1777 /tmp/.X11-unix 2>/dev/null || true
# If another user made it with a narrower mode, every display would fail and
# the walk below would end in a misleading "no free X display". Say why now.
if [ ! -w /tmp/.X11-unix ]; then
    echo "[novnc] /tmp/.X11-unix is not writable for uid $(id -u); the X server cannot start." >&2
    ls -ld /tmp/.X11-unix >&2 2>/dev/null || true
    exit 1
fi

# The MIT-MAGIC-COOKIE, in the session directory (0600 under umask 077).
XAUTHORITY="$OSP_APP_SOCK_DIR/Xauthority"
export XAUTHORITY
: > "$XAUTHORITY"
XAUTH_COOKIE="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"

# Try one display number. Returns 0 and sets VNC_DISPLAY on success, with Xvnc
# registered as the first (stopped-last) critical service.
#
# Xvnc listens for RFB only on $VNC_SOCK (0600, in a 0700 directory):
# -rfbport -1 turns the TCP listener off. -nolisten tcp and -nolisten local
# turn off the X server's own TCP and *abstract* sockets; the abstract one
# lives in the network namespace, which every session on the node shares, so
# a private /tmp would not hide it. X clients use the filesystem socket
# /tmp/.X11-unix/X<n> and the cookie.
#
# -SecurityTypes None and no VNC password: there is no socket anyone outside
# this session can reach, and a password file would be readable by the same
# uid that could read the token anyway. The gate is the authentication.
try_display() {
    local d=":$1" i
    xauth -f "$XAUTHORITY" add "$d" . "$XAUTH_COOKIE" 2>/dev/null || return 1
    rm -f "$VNC_SOCK"

    osp_start Xvnc -- env -u OSP_APP_TOKEN Xvnc "$d" \
        -rfbunixpath "$VNC_SOCK" -rfbunixmode 0600 \
        -rfbport -1 \
        -nolisten tcp -nolisten local \
        -SecurityTypes None \
        -geometry "$VNC_GEOMETRY" \
        -depth 24 \
        -auth "$XAUTHORITY" \
        -AlwaysShared \
        -desktop "app-novnc"
    local pid=$OSP_PID

    # Wait for the display and the RFB socket rather than sleeping and hoping.
    # Bail out early if Xvnc has already died -- the "display taken" case.
    for (( i = 0; i < 100; i++ )); do
        if DISPLAY="$d" xdpyinfo >/dev/null 2>&1 && [ -S "$VNC_SOCK" ]; then
            VNC_DISPLAY="$d"
            osp_register critical Xvnc "$pid" Xvnc
            return 0
        fi
        osp_alive "$pid" || break
        sleep 0.1
    done
    kill -TERM -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
}

# X display numbers are global to the node unless /tmp is private: the lock
# (/tmp/.X<n>-lock) and the socket (/tmp/.X11-unix/X<n>) live in /tmp. Walk
# :1, :2, ... until one takes. Under the run profile the first one always
# does. Setting VNC_DISPLAY explicitly demands that exact number.
if [ -n "${VNC_DISPLAY:-}" ]; then
    try_display "${VNC_DISPLAY#:}" || {
        echo "[novnc] display ${VNC_DISPLAY} is not available" >&2
        exit 1
    }
else
    _n=1
    until try_display "$_n"; do
        _n=$((_n + 1))
        [ "$_n" -le 64 ] || {
            echo "[novnc] no free X display between :1 and :64" >&2
            exit 1
        }
    done
fi

export DISPLAY="$VNC_DISPLAY"
echo "[novnc] Xvnc ready on $VNC_DISPLAY (rfb unix:$VNC_SOCK)"

# The desktop itself. fluxbox is the session leader: quitting it from its menu
# is a normal log-out and ends the session with status 0. Swap it for
# xfce4-session, or run ParaView/VMD/whatever directly, to build a different
# app-* on this same skeleton -- see the README. Its own chatter (on a fresh
# home it lists every default it fills in, about 150 lines, every session under
# the run profile) goes to a file in the session directory, not the job log.
osp_spawn leader fluxbox fluxbox -- env -u OSP_APP_TOKEN fluxbox -log "$OSP_APP_SOCK_DIR/fluxbox.log"
osp_spawn helper xterm   xterm   -- env -u OSP_APP_TOKEN xterm -geometry 100x30+80+60

# websockify serves the noVNC client AND bridges the websocket to Xvnc, Unix
# socket to Unix socket. Everything the browser fetches comes through the gate.
#
# Its TMPDIR is the session directory, not the job directory: websockify is
# Python and uses multiprocessing, whose default start method since Python
# 3.14 is a "forkserver" listening on a Unix socket in Python's temporary
# directory -- which follows TMPDIR, the job directory on shared storage under
# the run profile (plan NEW-17). websockify keeps no bulk data, so nothing is
# lost by keeping its temporary files in the private /tmp.
osp_spawn critical websockify websockify -- env -u OSP_APP_TOKEN TMPDIR="$OSP_APP_SOCK_DIR" websockify \
    --web=/usr/share/novnc \
    --unix-listen="$APP_SOCK" --unix-listen-mode=0600 \
    --unix-target="$VNC_SOCK"

# Do not start the gate until websockify is accepting connections, or the first
# request gets a 502.
_i=0
until [ -S "$APP_SOCK" ] && python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(1)
s.connect(sys.argv[1])' "$APP_SOCK" 2>/dev/null; do
    _i=$((_i + 1))
    [ "$_i" -lt 100 ] || { echo "[novnc] websockify did not start" >&2; exit 1; }
    sleep 0.1
done
echo "[novnc] websockify on unix:$APP_SOCK -> unix:$VNC_SOCK"

# The gate. token-gate.sh execs nginx, so the registered pid is nginx's.
osp_spawn critical gate nginx -- /app/web/token-gate.sh

osp_supervise
