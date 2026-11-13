# The shared session files (web/: the session contract, the token gate, the
# supervisor) come from app-template's kit image rather than a copy kept in
# this repo: a fix to them reaches this image by bumping this line.
FROM ghcr.io/onescienceplace/app-kit:1.1.0@sha256:8be57aac17696826c15692cf256dc69681ecf7b6137021ebeef09e4776118368 AS kit

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Xvnc (the X server), noVNC (the browser client), websockify (the bridge
# between them), a small window manager, and the gate's two dependencies.
# bash is the entrypoint's shell (web/supervise.sh needs `wait -n`); it is in
# the base image already and listed so that stays true.
#
# feh is not optional scenery: fluxbox's default style carries a `background:`
# directive, which makes it shell out to fbsetbg, which needs one of feh /
# Esetroot / display / hsetroot to exist. With none of them installed fbsetbg
# pops its complaint up as an xmessage dialog ON THE DESKTOP -- the first
# thing a user sees through noVNC.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates bash \
        tigervnc-standalone-server tigervnc-common xauth \
        novnc websockify \
        fluxbox xterm x11-utils \
        feh \
        nginx-light gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Fail the build, not the session, if a package lacks what the entrypoint
# depends on (what the gate and the supervisor need is checked by the kit's
# check-deps.sh, once web/ is in place below):
#   - Xvnc must listen for RFB on a Unix socket (rfbunixpath). TigerVNC's help
#     lists its parameters without the leading dash.
#   - websockify must listen on a Unix socket (--unix-listen).
RUN set -e; \
    Xvnc -help 2>&1 | grep -q rfbunixpath \
        || { echo "Xvnc has no rfbunixpath option" >&2; exit 1; }; \
    websockify --help 2>&1 | grep -q -- '--unix-listen' \
        || { echo "websockify has no --unix-listen option" >&2; exit 1; }; \
    echo "[build] Xvnc and websockify support what the entrypoint needs"

WORKDIR /app

# noVNC's landing page is vnc.html and it needs query parameters to connect on
# its own. The gate strips the query string after the token exchange, so bake
# the parameters into an index page instead of relying on the URL.
RUN printf '%s\n' \
      '<!doctype html><title>Remote desktop</title>' \
      '<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=true&resize=remote&reconnect=true">' \
      > /usr/share/novnc/index.html

# The X server needs this to exist before it can create its socket, and it
# will not create it itself as a non-root user.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Read-only .sif, unprivileged user: everything writable lives in /tmp or the
# working directory. XDG_RUNTIME_DIR is not set here: the entrypoint puts it
# inside the session's private directory.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache

# Branch B of the interactive contract: VNC has no URL-token auth, so the
# nginx gate owns OSP_APP_PORT and websockify sits behind it on a Unix socket.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`.
# OSP_APP_BIND defaults to 127.0.0.1 in web/session-env.sh; a local
# `docker run -p` needs -e OSP_APP_BIND=0.0.0.0.
ENV OSP_APP_PORT=6080 \
    VNC_GEOMETRY=1920x1080
# VNC_DISPLAY is deliberately unset: entrypoint.sh walks :1, :2, ... for a
# free one, because display numbers are global to the node when /tmp is
# shared. Set it at run time only to demand a specific number.
EXPOSE 6080

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

COPY --from=kit /app/web/ /app/web/
RUN /app/web/check-deps.sh
COPY entrypoint.sh /app/entrypoint.sh
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
# The kit's files arrive with their modes set.
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh

# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
