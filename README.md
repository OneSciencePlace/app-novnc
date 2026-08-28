# app-novnc

A remote desktop over VNC, reachable in a browser — **branch B** of the
interactive contract: VNC has no URL-token auth, so the nginx gate owns the
single exposed port and everything else hides on loopback.

```
browser ──https──▶ Satellite ──http──▶ 0.0.0.0:OSP_APP_PORT          nginx gate
                                              │  cookie / 403
                                              ▼
                                       127.0.0.1:OSP_APP_UPSTREAM_PORT  websockify
                                              │  + noVNC static files
                                              ▼
                                       127.0.0.1:5901              Xvnc + fluxbox
```

This is the skeleton for any VNC-backed app. Swap `fluxbox` for a full desktop,
or launch ParaView, VMD or a vendor GUI on the display instead, and the rest of
the plumbing is unchanged.

## Run it

```bash
TOKEN=$(openssl rand -hex 32)

docker run --rm --user "$(id -u):$(id -g)" \
  -p 6080:6080 -v "$PWD:/data" \
  -e OSP_APP_PORT=6080 -e OSP_APP_TOKEN="$TOKEN" \
  ghcr.io/onescienceplace/app-novnc:latest

apptainer pull oras://ghcr.io/onescienceplace/app-novnc-sif:latest
apptainer run --env OSP_APP_PORT=6080 --env OSP_APP_TOKEN="$TOKEN" \
  app-novnc-sif_latest.sif
```

Then open `https://<session>.<satellite-domain>/?token=$TOKEN`.

| Variable | Default | Meaning |
|---|---|---|
| `OSP_APP_PORT` | `6080` | the single port served — the nginx gate |
| `OSP_APP_TOKEN` | generated | per-session secret |
| `OSP_APP_TOKEN_NAME` | `token` | query parameter the token arrives in |
| `OSP_APP_UPSTREAM_PORT` | `6081` | loopback-only: websockify + noVNC |
| `VNC_DISPLAY` | auto | X display; RFB port is `5900 + n`. Unset by default — see below |
| `VNC_GEOMETRY` | `1920x1080` | desktop size |


## Design notes

**Display numbers are node-global.** The X lock (`/tmp/.X<n>-lock`) and socket
(`/tmp/.X11-unix/X<n>`) live in a `/tmp` that Apptainer usually shares with
every other user on the node, so a hardcoded `:1` means the second session on a
node dies with *Server is already active for display 1*. The entrypoint walks
`:1, :2, …` until one takes. Set `VNC_DISPLAY` explicitly only to demand a
specific number. The gate's scratch directory is scoped the same way
(`$TMPDIR/nginx-$(id -u)`), for the same reason.

**One port, one secret.** Only `OSP_APP_PORT` is bound on `0.0.0.0`. websockify and
Xvnc bind `127.0.0.1` and are unreachable from off-node.

**No VNC password, deliberately.** Xvnc runs `-SecurityTypes None -localhost`.
Its only client is websockify in this same container; a VNC password would be a
second secret protecting a socket nobody can reach. The browser-facing
authentication is the token gate, and that is the one that matters.

**The autoconnect page.** noVNC's client is `vnc.html` and needs query
parameters to connect on its own — but the gate strips the query string after
the token exchange. So the image bakes an `index.html` that redirects to
`vnc.html?autoconnect=true&resize=remote&reconnect=true`.

**`/tmp/.X11-unix`.** X only creates it when running as root, which we never
are. The Dockerfile pre-creates it for the Docker case; the entrypoint creates
it for the Apptainer case, where `/tmp` is usually bind-mounted from the host.

**Websockets.** The gate sets `proxy_http_version 1.1` plus the
`Upgrade`/`Connection` pair and an 86400s read timeout. Without those the noVNC
page loads and then sits there black.

**Scratch paths.** The entrypoint does not trust `$TMPDIR`. A scheduler's
`/scratch/$USER/job.N` is a host path Apptainer does not bind by default, so it
probes `$TMPDIR`, `/tmp`, `$HOME` in turn and reports on stderr which it took.
Pass `--bind /scratch` if you want the real one used.

## Layering another GUI app on this

Install it in the `Dockerfile`, then in `entrypoint.sh` replace the
`fluxbox` / `xterm` lines with your program — it inherits `DISPLAY` and renders
into the same Xvnc session:

```sh
paraview &                      # instead of fluxbox + xterm
```

Keep the window manager if the app opens more than one window.

## Build and test locally

Skip GitHub and the registry entirely:

```bash
docker build -t app-novnc:dev .              # --platform linux/amd64 on Apple Silicon
docker run --rm --user "$(id -u):$(id -g)" \
  -p 6080:6080 -v "$PWD:/data" \
  -e OSP_APP_PORT=6080 -e OSP_APP_TOKEN=localdev app-novnc:dev

docker save app-novnc:dev -o an.tar
apptainer build an.sif docker-archive://an.tar
apptainer run --env OSP_APP_PORT=6080 --env OSP_APP_TOKEN=localdev an.sif
```

Open `http://localhost:6080/?token=localdev`. Use *localhost*, not the host's
IP: the gate's cookie is marked `Secure`, and browsers make an exception for
`http://localhost` but not for any other plain-http origin, where the cookie is
dropped and every page load needs `?token=` again. Over localhost the whole
flow — cookie exchange, redirect, websocket — behaves as it will in production.

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
