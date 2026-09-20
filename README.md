# railway-ubuntu-ssh

The image behind the Railway template **Ubuntu SSH Workstation + Claude Code**
(`ghcr.io/will-bogusz/railway-ubuntu-ssh`). An Ubuntu 24.04 dev box you reach over SSH
(through Railway's TCP proxy) or a browser terminal on `$PORT`, with `/home/dev` on a volume
and Claude Code, Node LTS, Python 3, build-essential, git and `gh` preinstalled.

Deploy it: <https://railway.com/deploy/ubuntu-ssh-workstation>

## Runtime contract

| Variable | Required | Effect |
|---|---|---|
| `SSH_PASSWORD` | yes | Password for user `dev` (SSH and browser terminal). The template generates it. Blank → the container prints why and exits. |
| `PORT` | no (default `8080`) | The browser terminal's port; Railway injects it and healthchecks it. |
| `AUTHORIZED_KEYS` | no | Public keys, one per line, written to `/etc/ssh/authorized_keys.d/dev`. `~/.ssh/authorized_keys` on the volume also works. |
| `ANTHROPIC_API_KEY` | no | Exported to login shells; Claude Code uses it. Without it, `claude` offers the subscription login. |
| `GITHUB_TOKEN` | no | Exported to login shells; a system git credential helper for `github.com` and `gh` use it. |
| `TZ` | no | Zoneinfo name; sets `/etc/localtime`. |

Every other service variable is exported to login shells too (via
`/etc/profile.d/10-railway-env.sh`, mode 0640 `root:dev`), except `SSH_PASSWORD`.

Processes (all supervised by the entrypoint; if one dies the container exits 1):

- `sshd` on `0.0.0.0:22` — `AllowUsers dev`, root login off, password + public key auth,
  host keys persisted in `/home/dev/.devbox/` (root-only) so redeploys keep their identity.
- `ttyd` on `127.0.0.1:7681` as `dev`, running `tmux new-session -A -s main` — closing the
  browser tab keeps the session.
- `nginx` on `0.0.0.0:$PORT` — basic auth `dev:$SSH_PASSWORD` in front of ttyd (websocket
  proxied); `GET /healthz` is unauthenticated and proxies to ttyd's index, so a 200 proves
  the terminal is up.

`dev` has `sudo` without a password. The image's pinned Claude Code lives in
`/usr/local`; `~/.local/bin` and `~/.npm-global/bin` come first on `PATH`, so users update
into the volume (`curl -fsSL https://claude.ai/install.sh | bash`, `npm i -g …`) without
touching the image.

## Pins

| Component | Pin | Where |
|---|---|---|
| ubuntu:24.04 | index digest in `Dockerfile` `UBUNTU_DIGEST` | Docker Hub |
| Node.js | `NODE_VERSION` + `NODE_SHA256` | nodejs.org tarball |
| ttyd | `TTYD_VERSION` + `TTYD_SHA256` | GitHub release |
| gh | `GH_VERSION` + `GH_SHA256` | GitHub release `.deb` |
| Claude Code | `CLAUDE_CODE_VERSION` | npm |

apt packages come from the Ubuntu 24.04 archive at build time.

## Modes and brute-force protection

`DEVBOX_SSH=off` runs the browser terminal only (the **Ubuntu Web Terminal** template,
`railway.com/deploy/ubuntu-web-terminal`); `PASSWORD` is accepted as an alias of `SSH_PASSWORD`.
With SSH on, sshd's `PerSourceMaxStartups 3` / `MaxStartups 10:30:60` throttle unauthenticated
connections per source; when the container has `CAP_NET_ADMIN` (not on Railway today) the
entrypoint also starts fail2ban (`/etc/fail2ban/jail.d/devbox.conf`, 5 failures / 10 min → 1 h
ban) fed by a syslog-shaped copy of sshd's stderr at `/run/devbox-sshd.log`. Verified on Docker
with `--cap-add NET_ADMIN`: 6 bad passwords → source banned, next connection reset.

## Build

GitHub Actions builds and pushes (`.github/workflows/build.yml`): **Actions → build → Run
workflow**, optional tag input (default `24.04-YYYYMMDD`). The run summary prints the
`name:tag@sha256:…` reference. `build.sh` does the same on a docker host with a token that
has `write:packages`; the laptop never runs containers.

Bump the ARGs, rebuild under a new date tag, then update the template's image reference in
Railway's template editor. Existing deployments keep the old digest.

## Local check

```bash
docker run -d --name devbox -e SSH_PASSWORD=test1234 -e PORT=8080 -p 2222:22 -p 8080:8080 \
  -v devbox-home:/home/dev ghcr.io/will-bogusz/railway-ubuntu-ssh:24.04-20260920
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/healthz      # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/             # 401
curl -s -o /dev/null -w '%{http_code}\n' -u dev:test1234 http://localhost:8080/  # 200
ssh -p 2222 dev@localhost claude --version
```

License: MIT.
