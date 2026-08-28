#!/bin/sh
# token-gate.sh - start the nginx token gate in the foreground.
#
# For apps with NO native URL-token auth (noVNC, RStudio, ParaView-over-VNC).
# Apps that have one -- JupyterLab and its JUPYTER_TOKEN -- should bind
# directly to OSP_APP_PORT and skip this entirely.
#
# Layout:
#   0.0.0.0:$OSP_APP_PORT           nginx  <- the only port anything outside sees
#   127.0.0.1:$OSP_APP_UPSTREAM_PORT  the real app, unreachable from off-node
#
# Start the app first (backgrounded, bound to 127.0.0.1), then exec this.
set -eu

: "${OSP_APP_UPSTREAM_PORT:?OSP_APP_UPSTREAM_PORT must be set before starting the gate}"
: "${OSP_APP_PORT:?source web/session-env.sh first}"
: "${OSP_APP_TOKEN:?source web/session-env.sh first}"
: "${OSP_APP_TOKEN_NAME:?source web/session-env.sh first}"

# Everything nginx writes goes here: a .sif is read-only, and /var/log/nginx,
# /var/lib/nginx and /run are all inside it. Scoped by uid because under
# Apptainer /tmp is usually the compute node's, shared with every other user
# on it -- a fixed path means the second session cannot write to a directory
# the first one owns.
NGINX_DIR="${TMPDIR:-/tmp}/nginx-$(id -u)"

# The rendered config contains OSP_APP_TOKEN in plaintext, and this lives in a
# /tmp that Apptainer usually shares with the whole node. Default umask would
# leave it 0644 in a 0755 directory, readable by every other user there.
umask 077
mkdir -p "$NGINX_DIR"

# The restricted form of envsubst substitutes ONLY these four names, leaving
# nginx's own $variables in the template untouched.
export OSP_APP_PORT OSP_APP_TOKEN OSP_APP_TOKEN_NAME OSP_APP_UPSTREAM_PORT NGINX_DIR
envsubst '${OSP_APP_PORT} ${OSP_APP_TOKEN} ${OSP_APP_TOKEN_NAME} ${OSP_APP_UPSTREAM_PORT} ${NGINX_DIR}' \
    < /app/web/nginx.conf.template > "$NGINX_DIR/nginx.conf"

nginx -t -c "$NGINX_DIR/nginx.conf"
exec nginx -c "$NGINX_DIR/nginx.conf"
