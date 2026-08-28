# session-env.sh - the interactive-app session contract. SOURCE this from
# entrypoint.sh (". /app/web/session-env.sh"), do not exec it.
#
# Establishes three variables that every web or VNC app in this family honours,
# all of them settable on the `docker run` / `apptainer run` command line:
#
#   OSP_APP_PORT        the single TCP port the container listens on (0.0.0.0).
#                   Must be >= 1024: the container runs as an unprivileged
#                   user with no sudo and no fakeroot, and the Satellite
#                   reverse proxy refuses to proxy to privileged ports.
#   OSP_APP_TOKEN       the per-session secret. Generated here if unset, so a
#                   local `docker run` still works, but a real session should
#                   pass one in.
#   OSP_APP_TOKEN_NAME  the query parameter the token arrives in, so the entry URL
#                   is  https://<session>.<satellite-domain>/?<name>=<token>
#                   Default `token`, which is what JupyterLab uses natively.
#                   nginx maps it to $arg_<name> / $cookie_<name>, so keep it
#                   to [A-Za-z0-9_].

: "${OSP_APP_PORT:=8080}"
: "${OSP_APP_TOKEN_NAME:=token}"

if [ -z "${OSP_APP_TOKEN:-}" ]; then
    # od + /dev/urandom rather than openssl: no extra package in the image.
    OSP_APP_TOKEN="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
    echo "[session] OSP_APP_TOKEN was not set; generated one for this session." >&2
fi

case "$OSP_APP_PORT" in
    ''|*[!0-9]*) echo "[session] OSP_APP_PORT must be a number, got '$OSP_APP_PORT'" >&2; exit 1 ;;
esac
[ "$OSP_APP_PORT" -ge 1024 ] || { echo "[session] OSP_APP_PORT must be >= 1024 (unprivileged)" >&2; exit 1; }

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

export OSP_APP_PORT OSP_APP_TOKEN OSP_APP_TOKEN_NAME

# Printed so the job script can hand both values to Satellite's redeemtoken
# step and build the user-facing link.
echo "[session] port      : ${OSP_APP_PORT}"
echo "[session] entry path: /?${OSP_APP_TOKEN_NAME}=${OSP_APP_TOKEN}"
