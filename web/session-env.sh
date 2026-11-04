# session-env.sh - the interactive-app session contract. SOURCE this from
# entrypoint.sh (". /app/web/session-env.sh"), do not exec it. POSIX sh, so
# both the sh entrypoints (Jupyter) and the bash ones (VNC desktops) can use it.
#
# Settable by the caller (`docker run -e`, `apptainer run --env`, or the
# launcher's APPTAINERENV_* environment):
#
#   OSP_APP_PORT        the single TCP port the container listens on. Must be
#                       >= 1024: the container runs as an unprivileged user with
#                       no sudo and no fakeroot.
#   OSP_APP_BIND        the address that port is bound to. Default 127.0.0.1:
#                       the launcher's reverse SSH tunnel reaches it there, and
#                       nothing else on the node or the cluster network can.
#                       Local `docker run -p` needs 0.0.0.0 inside the container.
#   OSP_APP_TOKEN       the per-session secret. NEVER pass it on a command line
#                       (`ps` shows command lines to everyone on the node): use
#                       APPTAINERENV_OSP_APP_TOKEN, or `docker run -e OSP_APP_TOKEN`
#                       with no `=value`. Generated here if unset, so a local
#                       `docker run` still works.
#   OSP_APP_TOKEN_NAME  the query parameter the token arrives in, so the entry
#                       URL is  https://<session>.<satellite-domain>/?<name>=<token>
#                       Default `token`, which is what JupyterLab uses natively.
#                       nginx maps it to $arg_<name> / $cookie_<name>, so it is
#                       restricted to [A-Za-z0-9_].
#
# Set here, never by the caller:
#
#   OSP_APP_SOCK_DIR    a fresh 0700 directory under /tmp, unique to this
#                       session. Every secret, socket, rendered config and pid
#                       file the session creates goes in here. Under the OSP
#                       interactive run profile (--contain) /tmp is private to
#                       the session, so nothing in here is visible to any other
#                       session -- including other sessions of the same uid.
#                       Bulk scratch data goes under $TMPDIR instead (the job
#                       directory under the profile): /tmp is small there.

# Everything this session creates is private to it. The entrypoint sets this
# too; it is repeated so that sourcing this file is enough on its own.
umask 077

: "${OSP_APP_PORT:=8080}"
: "${OSP_APP_TOKEN_NAME:=token}"
: "${OSP_APP_BIND:=127.0.0.1}"

case "$OSP_APP_PORT" in
    ''|*[!0-9]*) echo "[session] OSP_APP_PORT must be a number, got '$OSP_APP_PORT'" >&2; exit 1 ;;
esac
[ "$OSP_APP_PORT" -ge 1024 ] || { echo "[session] OSP_APP_PORT must be >= 1024 (unprivileged)" >&2; exit 1; }

# These three are substituted into nginx's configuration (branch B) or handed
# to the app (branch A). Restricting their characters means none of them can
# ever change the meaning of the configuration they are written into.
case "$OSP_APP_TOKEN_NAME" in
    ''|*[!A-Za-z0-9_]*) echo "[session] OSP_APP_TOKEN_NAME must match [A-Za-z0-9_]+, got '$OSP_APP_TOKEN_NAME'" >&2; exit 1 ;;
esac
case "$OSP_APP_BIND" in
    ''|*[!0-9A-Fa-f.:]*) echo "[session] OSP_APP_BIND must be an IP address, got '$OSP_APP_BIND'" >&2; exit 1 ;;
esac

_osp_token_generated=0
if [ -z "${OSP_APP_TOKEN:-}" ]; then
    # od + /dev/urandom rather than openssl: no extra package in the image.
    OSP_APP_TOKEN="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
    _osp_token_generated=1
    echo "[session] OSP_APP_TOKEN was not set; generated one for this session." >&2
fi
# URL-safe characters only: nginx compares the raw (undecoded) query string,
# so anything that needs percent-encoding could never match anyway.
case "$OSP_APP_TOKEN" in
    *[!A-Za-z0-9._~-]*) echo "[session] OSP_APP_TOKEN must match [A-Za-z0-9._~-]+" >&2; exit 1 ;;
esac
# ...and at most 200 characters, so it fits the gate's map_hash_bucket_size.
[ "${#OSP_APP_TOKEN}" -le 200 ] || { echo "[session] OSP_APP_TOKEN is longer than 200 characters" >&2; exit 1; }

# The session's private directory. Always created fresh under /tmp, never
# taken from the environment and never under $TMPDIR: $TMPDIR is the job
# directory under the run profile, on shared storage, where neither secrets
# nor Unix sockets belong. mktemp makes it 0700 with an unguessable name, so
# even without a private /tmp it is never a directory another session made.
OSP_APP_SOCK_DIR="$(mktemp -d /tmp/osp-app-XXXXXXXX)" || {
    echo "[session] cannot create a session directory under /tmp" >&2
    exit 1
}
chmod 0700 "$OSP_APP_SOCK_DIR"

# `whoami`, `ls -l` and anything else calling getpwuid() needs a passwd entry,
# and `docker run --user <uid>` hands the container a uid the image has never
# heard of. Apptainer generates the entry for you; Docker does not. /etc/passwd
# is group-writable in this image, so `--user "$(id -u):0"` lets us add one.
if ! id -un >/dev/null 2>&1; then
    if [ -w /etc/passwd ]; then
        printf '%s:x:%s:%s:OSP app user:%s:/bin/sh\n' \
            "${OSP_APP_USER:-ospuser}" "$(id -u)" "$(id -g)" "${HOME:-/tmp}" >> /etc/passwd
        if [ -w /etc/group ] && ! id -gn >/dev/null 2>&1; then
            printf '%s:x:%s:\n' "${OSP_APP_USER:-ospuser}" "$(id -g)" >> /etc/group
        fi
        echo "[session] added a passwd entry for uid $(id -u) as ${OSP_APP_USER:-ospuser}"
    else
        echo "[session] uid $(id -u) has no passwd entry; whoami will fail (harmless)." >&2
        echo "[session] see the README if you want a username under docker run." >&2
    fi
fi

export OSP_APP_PORT OSP_APP_BIND OSP_APP_TOKEN OSP_APP_TOKEN_NAME OSP_APP_SOCK_DIR

# The port, for the job script. The token is printed only when it was
# generated here (a local run, where nobody else knows it). When the launcher
# supplied it, the launcher already has it, and printing it would put the
# secret into the job's output files.
echo "[session] port      : ${OSP_APP_BIND}:${OSP_APP_PORT}"
if [ "$_osp_token_generated" = 1 ]; then
    echo "[session] entry path: /?${OSP_APP_TOKEN_NAME}=${OSP_APP_TOKEN}"
else
    echo "[session] entry path: /?${OSP_APP_TOKEN_NAME}=<token supplied by the launcher>"
fi
unset _osp_token_generated
