# app-novnc

A remote desktop over VNC, reachable in a browser — **branch B** of the
interactive contract: VNC has no URL-token auth, so the nginx gate owns the
one TCP port and everything behind it is a Unix socket in the session's
private directory.

```
browser ──https──▶ Satellite ──ssh tunnel──▶ 127.0.0.1:OSP_APP_PORT   nginx gate
                                                    │  cookie / 403
                                                    ▼
                                    $OSP_APP_SOCK_DIR/app.sock        websockify
                                                    │  + noVNC static files
                                                    ▼
                                    $OSP_APP_SOCK_DIR/vnc.sock        Xvnc + fluxbox
```

This is the skeleton for any VNC-backed app. Swap `fluxbox` for a full desktop,
or launch ParaView, VMD or a vendor GUI on the display instead, and the rest of
the plumbing is unchanged.

## Run it

The token is never put on a command line: `ps` shows command lines to every
user on a node. Pass it through the environment.

```bash
export OSP_APP_TOKEN=$(openssl rand -hex 32)

# Docker (local). -e OSP_APP_TOKEN with no "=value" copies it from your
# environment. OSP_APP_BIND=0.0.0.0 because `-p` cannot reach a container's
# loopback; the host side is still published on 127.0.0.1 only.
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:6080:6080 -v "$PWD:/data" \
  -e OSP_APP_PORT=6080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN \
  ghcr.io/onescienceplace/app-novnc:latest

# Apptainer, under the OSP interactive run profile.
# APPTAINERENV_<NAME> reaches the container as <NAME>, even with --cleanenv.
apptainer pull oras://ghcr.io/onescienceplace/app-novnc-sif:latest   # production pins <version>@sha256:<digest>
export APPTAINERENV_OSP_APP_TOKEN="$OSP_APP_TOKEN"
apptainer run \
  --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" \
  --env OSP_APP_PORT=6080 --env TMPDIR="$PWD/tmp" \
  app-novnc-sif_latest.sif
```

Through OSP, open `https://<session-label>.<sat-id>.sat.<domain>/?token=<token>`.
Locally, `http://localhost:6080/?token=$OSP_APP_TOKEN` (Docker), or forward the
port first for Apptainer on a cluster node: `ssh -L 6080:127.0.0.1:6080 <node>`.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `6080` | the one TCP port — the nginx gate |
| `OSP_APP_BIND` | `127.0.0.1` | address the gate listens on; `0.0.0.0` only for local `docker run -p` |
| `OSP_APP_TOKEN` | generated | per-session secret; environment only, never a command-line argument |
| `OSP_APP_TOKEN_NAME` | `token` | query parameter the token arrives in (`[A-Za-z0-9_]`) |
| `VNC_DISPLAY` | auto | X display number. Unset by default — see below |
| `VNC_GEOMETRY` | `1920x1080` | desktop size |
| `OSP_APP_HEALTH_PATH` | `vnc.html` | what the gate's `/healthz` asks websockify for |

`OSP_APP_SOCK_DIR` is set by `web/session-env.sh`, never by the caller: a fresh
`0700` directory under `/tmp` that holds every secret, socket and rendered
config of the session.

## Design notes

**One TCP listener, on loopback.** Only the gate has a TCP port, and it binds
`127.0.0.1` — the launcher's reverse SSH tunnel connects there and nothing else
needs to. websockify and Xvnc have no TCP port at all: under Apptainer the
container shares the node's network, so a loopback port would be reachable by
every other process on the node, token or no token.

**Behind the gate, Unix sockets only.** Xvnc listens for RFB on
`$OSP_APP_SOCK_DIR/vnc.sock` (`-rfbunixpath`, `-rfbport -1`), websockify on
`$OSP_APP_SOCK_DIR/app.sock` (`--unix-listen`). Both are `0600` in a `0700`
directory. Xvnc also runs `-nolisten tcp -nolisten local`: the second one
removes the X server's *abstract* socket, which lives in the shared network
namespace and would be reachable from other sessions even with a private
`/tmp`. X clients use the filesystem socket `/tmp/.X11-unix/X<n>` and the
cookie in `$OSP_APP_SOCK_DIR/Xauthority`.

**The session directory.** `$OSP_APP_SOCK_DIR` is created with `mktemp -d`
under `/tmp`, never under `$TMPDIR`: under the run profile `/tmp` is private to
the session, while `$TMPDIR` is the job directory on shared storage. The
rendered `nginx.conf` (which holds the token), the X cookie, the sockets and
`XDG_RUNTIME_DIR` all live there, and the directory is removed when the
session ends. websockify's own temporary files go there too (`TMPDIR` for it
only): it is Python, and since Python 3.14 its multiprocessing starts a
"forkserver" that listens on a Unix socket in the temporary directory, which
must not be the job directory.

**No VNC password, deliberately.** Xvnc runs `-SecurityTypes None`. There is
no socket anyone outside the session can reach, and a password file would be
readable by the same uid that could read the token anyway. The gate is the
authentication.

**Supervision.** The session is five processes, so the entrypoint does not
`exec` any of them; it stays and supervises them through `web/supervise.sh`.
Each service runs in its own process group, so stopping it stops what it
started too. The session ends when Xvnc, fluxbox, websockify or the gate exits:

| How it ended | Exit status |
|---|---|
| fluxbox quit normally (log out from its menu) | `0` |
| any of the four died or was killed | `1` |
| the job was cancelled / `docker stop` (SIGTERM) | `143` |

Every service except the gate starts without `OSP_APP_TOKEN` in its
environment, so the desktop, its terminal and whatever the user runs never
hold the token. Cleanup stops everything in reverse start order, Xvnc last,
then removes the session directory. Service output reaches the job's stderr with a `[name] `
prefix; fluxbox's own chatter goes to `fluxbox.log` in the session directory.

**Readiness.** `GET /healthz` is ungated and returns `ok` (200) once websockify
answers on its socket, 503 before. Nothing from the app is returned through
it. The launcher should poll it before handing the link to Satellite.

**Display numbers.** With the run profile `/tmp` is private and `:1` is always
free. Without it, the X lock (`/tmp/.X<n>-lock`) and socket
(`/tmp/.X11-unix/X<n>`) are shared with every user on the node, so the
entrypoint walks `:1, :2, …` until one takes. Set `VNC_DISPLAY` only to demand
a specific number.

**The autoconnect page.** noVNC's client is `vnc.html` and needs query
parameters to connect on its own — but the gate strips the query string after
the token exchange. So the image bakes an `index.html` that redirects to
`vnc.html?autoconnect=true&resize=remote&reconnect=true`.

**`/tmp/.X11-unix`.** X only creates it when running as root, which we never
are. The Dockerfile pre-creates it for the Docker case; the entrypoint creates
it for the Apptainer case, explicitly mode `1777` so that on a node-shared
`/tmp` it never locks other users out. If it already exists and is not
writable for us, the entrypoint stops and says so rather than walking every
display number to a misleading "no free X display".

**`HOME` and `XDG_CACHE_HOME`.** The image defaults them to `/tmp` and
`/tmp/.cache`. Where those are still in effect, the entrypoint moves them into
the session directory, because on a node-shared `/tmp` they would belong to
whichever user ran first. A value the job sets itself — including the real
`HOME` Apptainer normally provides — is kept.

**Websockets.** The gate sets `proxy_http_version 1.1` plus the
`Upgrade`/`Connection` pair and an 86400s read timeout. Without those the noVNC
page loads and then sits there black.

**Scratch paths.** Bulk scratch goes to `$TMPDIR`; the run profile sets it to
the job directory. The entrypoint does not trust an inherited `$TMPDIR` — a
scheduler's `/scratch/$USER/job.N` may not be bound into the container — so it
probes `$TMPDIR`, `/tmp`, `$HOME` in turn and reports on stderr which it took.
Never bind a scratch *parent* (`/scratch`) to fix this: it exposes every other
job's directory to the same uid.

## Layering another GUI app on this

Install it in the `Dockerfile`, then in `entrypoint.sh` replace the
`fluxbox` / `xterm` lines with your program, started through the supervisor —
it inherits `DISPLAY` and renders into the same Xvnc session:

```bash
# instead of fluxbox + xterm; "paraview" is what /proc/<pid>/comm shows
osp_spawn leader paraview paraview -- paraview
```

Keep the window manager (as a `critical` service) if the app opens more than
one window. The program must stay in the foreground: a launcher that forks and
exits fails the supervisor's launch check, which is the signal to start the
long-lived binary directly.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
bash -n entrypoint.sh                        # syntax, before anything else
# web/ is not in this repository: the build copies it from the kit image named
# at the top of the Dockerfile (ghcr.io/onescienceplace/app-kit).
docker build -t app-novnc:dev .              # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -p 127.0.0.1:6080:6080 -v "$PWD:/data" \
  -e OSP_APP_PORT=6080 -e OSP_APP_BIND=0.0.0.0 -e OSP_APP_TOKEN=localdev \
  app-novnc:dev

docker save app-novnc:dev -o an.tar
apptainer build an.sif docker-archive://an.tar
export APPTAINERENV_OSP_APP_TOKEN=localdev
apptainer run --contain --pid --ipc --cleanenv --no-mount bind-paths,cwd \
  --pwd "$PWD" --bind "$PWD:$PWD" --env OSP_APP_PORT=6080 --env TMPDIR="$PWD/tmp" an.sif
```

(`localdev` on the command line is fine for a throwaway local token; never do
it with a real one.)

Open `http://localhost:6080/?token=localdev`. Use *localhost*, not the host's
IP: the gate's cookie is marked `Secure`, and browsers make an exception for
`http://localhost` but not for any other plain-http origin, where the cookie is
dropped and every page load needs `?token=` again. Over localhost the whole
flow — cookie exchange, redirect, websocket — behaves as it will in production.

Isolation between two sessions of the same account is checked per system,
before interactive apps are offered there (OSP's internal validation procedure).

### Why `--user`

Docker runs the container as root, so anything it writes into the bind-mounted
directory lands on your disk owned by `root` and needs `sudo` to delete.
`--user "$(id -u):$(id -g)"` makes the container write as you, and matches how
Apptainer runs it — Apptainer is always the invoking user, so it never has this
problem.

To reclaim files a previous root-owned run left behind:

```bash
sudo chown -R "$(id -u):$(id -g)" .
```

The one visible side effect: that uid has no `/etc/passwd` entry inside the
container, so `whoami` fails and `ls -l` shows bare numbers. Nothing actually
breaks — only code calling `getpwuid()` notices — and Apptainer generates the
entry itself, so this never shows up in production. If you want a name locally:

```bash
# 1. Let the entrypoint add one. /etc/passwd is group-writable in this image,
#    so running with group 0 is enough. You become `ospuser`.
docker run --rm --user "$(id -u):0" ...

# 2. Or show the container your real identity, keeping your own gid, so that
#    whoami returns your actual username.
docker run --rm --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro ...
```

Set `OSP_APP_USER` to change the name option 1 uses.

`apptainer build` from a local archive needs no root and no fakeroot. Test the
`.sif` and not just the image: read-only-filesystem bugs never show up under
`docker run`.
