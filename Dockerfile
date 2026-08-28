FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# Xvnc (the X server), noVNC (the browser client), websockify (the bridge
# between them), a small window manager, and the gate's two dependencies.
#
# feh is not optional scenery: fluxbox's default style carries a `background:`
# directive, which makes it shell out to fbsetbg, which needs one of feh /
# Esetroot / display / hsetroot to exist. With none of them installed fbsetbg
# pops its complaint up as an xmessage dialog ON THE DESKTOP -- the first
# thing a user sees through noVNC.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        tigervnc-standalone-server tigervnc-common xauth \
        novnc websockify \
        fluxbox xterm x11-utils \
        feh \
        nginx-light gettext-base \
    && rm -rf /var/lib/apt/lists/*

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

# Read-only .sif, unprivileged user: everything writable lives in /tmp.
ENV HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    XDG_RUNTIME_DIR=/tmp/run

# Branch B of the interactive contract: VNC has no URL-token auth, so the
# nginx gate owns OSP_APP_PORT and websockify hides on OSP_APP_UPSTREAM_PORT.
# OSP_APP_TOKEN_NAME is deliberately NOT an ENV here. Its value is a parameter
# name, not a secret, but BuildKit's SecretsUsedInArgOrEnv check matches on
# the word TOKEN and warns. web/session-env.sh already defaults it to `token`,
# so the ENV was redundant.
ENV OSP_APP_PORT=6080 \
    OSP_APP_UPSTREAM_PORT=6081 \
    VNC_GEOMETRY=1920x1080
# VNC_DISPLAY is deliberately unset: entrypoint.sh walks :1, :2, ... for a
# free one, because display numbers are global to the node. Set it at run
# time only to demand a specific number.
EXPOSE 6080

# /etc/passwd group-writable so entrypoint can add an entry for the runtime uid
# when run as `--user "$(id -u):0"`. Harmless otherwise, and read-only under
# Apptainer, which supplies the entry itself.
RUN chmod g=u /etc/passwd /etc/group

COPY web/ /app/web/
COPY entrypoint.sh /app/entrypoint.sh
# Explicit modes. COPY preserves the build context's permissions, so a checkout
# made under a restrictive umask yields 0600/0700 files that the runtime user --
# `docker run --user`, or any user at all under Apptainer -- cannot even read.
# Git only tracks the exec bit, so this is not something the repo can guarantee.
RUN chmod -R a+rX /app \
    && chmod 0755 /app/entrypoint.sh /app/web/token-gate.sh /app/web/session-env.sh

# /data is a mount point. Make it writable by whoever runs the container, so a
# run without a bind mount still works for a non-root user.
RUN mkdir -p /data && chmod 1777 /data

WORKDIR /data

ENTRYPOINT ["/app/entrypoint.sh"]
