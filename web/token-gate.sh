#!/bin/sh
# token-gate.sh - start the nginx token gate in the foreground.
#
# For apps with NO native URL-token auth (noVNC, RStudio, ParaView-over-VNC).
# Apps that have one -- JupyterLab and its JUPYTER_TOKEN -- bind OSP_APP_BIND:
# OSP_APP_PORT themselves and skip this entirely.
#
# Layout:
#   $OSP_APP_BIND:$OSP_APP_PORT     nginx  <- the only TCP listener in the session
#   $OSP_APP_SOCK_DIR/app.sock      the real app, a Unix socket: no port at all
#
# Start the app first, listening on $OSP_APP_SOCK_DIR/app.sock, then either
# `exec` this (a single-process app) or start it as one more supervised service
# (web/supervise.sh). Either way it ends by exec'ing nginx, so its pid IS nginx.
set -eu

: "${OSP_APP_SOCK_DIR:?source web/session-env.sh first}"
: "${OSP_APP_PORT:?source web/session-env.sh first}"
: "${OSP_APP_TOKEN:?source web/session-env.sh first}"
: "${OSP_APP_TOKEN_NAME:?source web/session-env.sh first}"
: "${OSP_APP_BIND:=127.0.0.1}"

# The upstream path /healthz checks, relative to the app's root. Set by the app
# (noVNC: vnc.html). Empty means `/`. Substituted into the config, so it is
# restricted to plain path characters.
: "${OSP_APP_HEALTH_PATH:=}"
case "$OSP_APP_HEALTH_PATH" in
    /*|*[!A-Za-z0-9._/-]*)
        echo "[gate] OSP_APP_HEALTH_PATH must be a relative path of [A-Za-z0-9._/-], got '$OSP_APP_HEALTH_PATH'" >&2
        exit 1 ;;
esac

# Everything nginx writes goes inside the session directory: the .sif is
# read-only, and the rendered config holds the token in plaintext. One
# directory per session, never per uid -- under a community account every
# session on a node has the same uid.
NGINX_DIR="$OSP_APP_SOCK_DIR/nginx"
umask 077
mkdir -p "$NGINX_DIR"
printf 'ok\n' > "$NGINX_DIR/healthz.ok"    # the body /healthz returns when ready

export OSP_APP_PORT OSP_APP_BIND OSP_APP_TOKEN OSP_APP_TOKEN_NAME \
       OSP_APP_SOCK_DIR OSP_APP_HEALTH_PATH NGINX_DIR
# The restricted form of envsubst substitutes ONLY these names, leaving nginx's
# own $variables in the template untouched.
# shellcheck disable=SC2016  # single quotes on purpose: names, not values
envsubst '${OSP_APP_PORT} ${OSP_APP_BIND} ${OSP_APP_TOKEN} ${OSP_APP_TOKEN_NAME} ${OSP_APP_SOCK_DIR} ${OSP_APP_HEALTH_PATH} ${NGINX_DIR}' \
    < /app/web/nginx.conf.template > "$NGINX_DIR/nginx.conf"

# -e stderr: nginx opens its default error log before it reads the config,
# and that default is inside the read-only image.
nginx -e stderr -t -q -c "$NGINX_DIR/nginx.conf"
exec nginx -e stderr -c "$NGINX_DIR/nginx.conf"
