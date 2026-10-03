#!/bin/bash
# Boot: seed the home volume, set the dev password, wire optional variables,
# then run sshd (port 22, behind Railway's TCP proxy), ttyd (loopback) and
# nginx ($PORT, basic auth in front of ttyd, /healthz open). Each daemon runs
# under a respawn loop: a daemon that dies (OOM kill, `sudo service ssh
# restart`, a stray pkill) comes back in 2 s instead of taking the container
# down, because Railway records every container exit after a kill as a crash.
# The container stops only on SIGTERM. Never prints a secret.
set -euo pipefail

HOME_DIR=/home/dev
STATE_DIR="$HOME_DIR/.devbox"   # root-only; ssh host keys, so redeploys keep their identity
PORT="${PORT:-8080}"
TTYD_PORT=7681

fail() {
  echo "devbox: $*" >&2
  sleep 3   # Railway drops the logs of a container that exits within ~1 s
  exit 1
}

# PASSWORD is the web-terminal template's name for the same secret.
SSH_PASSWORD="${SSH_PASSWORD:-${PASSWORD:-}}"
[ -n "$SSH_PASSWORD" ] || fail "PASSWORD is empty. Set it in the service's Variables tab (the template generates one) and redeploy."
case "${DEVBOX_SSH:-on}" in off|no|false|0) SSH_ENABLED=0;; *) SSH_ENABLED=1;; esac
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got '$PORT'";; esac

# --- home volume -----------------------------------------------------------
# Railway mounts the volume root-owned with a lost+found directory. Seed the
# skeleton on first boot, then hand the directory to dev. Non-recursive after
# that: the volume is the user's and may be large.
mkdir -p "$HOME_DIR"
if [ ! -e "$HOME_DIR/.bashrc" ]; then
  cp -a /etc/skel/. "$HOME_DIR"/
  find "$HOME_DIR" -mindepth 1 -maxdepth 1 -not -name lost+found -exec chown -R dev:dev {} +
fi
chown dev:dev "$HOME_DIR"
chmod 0750 "$HOME_DIR"
install -d -o dev -g dev -m 0700 "$HOME_DIR/.ssh"
install -d -o root -g root -m 0700 "$STATE_DIR"

# --- dev account -----------------------------------------------------------
echo "dev:$SSH_PASSWORD" | chpasswd

if [ -n "${AUTHORIZED_KEYS:-}" ]; then
  printf '%s\n' "$AUTHORIZED_KEYS" | sed 's/\r$//' > /etc/ssh/authorized_keys.d/dev
  chmod 0644 /etc/ssh/authorized_keys.d/dev
else
  rm -f /etc/ssh/authorized_keys.d/dev
fi

# SSH_PASSWORD_AUTH=no turns SSH password login off once a key is available.
# The browser terminal keeps using the password. Refused without a key so a
# typo cannot lock the box.
case "${SSH_PASSWORD_AUTH:-yes}" in
  no|false|0|off)
    if [ -s /etc/ssh/authorized_keys.d/dev ] || [ -s "$HOME_DIR/.ssh/authorized_keys" ]; then
      echo 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/05-local.conf
    else
      echo "devbox: SSH_PASSWORD_AUTH=no ignored: no authorized key found (AUTHORIZED_KEYS or ~/.ssh/authorized_keys)" >&2
      rm -f /etc/ssh/sshd_config.d/05-local.conf
    fi;;
  *) rm -f /etc/ssh/sshd_config.d/05-local.conf;;
esac

if [ "$SSH_ENABLED" = 1 ]; then
  for type in ed25519 rsa ecdsa; do
    key="$STATE_DIR/ssh_host_${type}_key"
    [ -f "$key" ] || ssh-keygen -q -t "$type" -N '' -f "$key" >/dev/null
  done
  mkdir -p /run/sshd && chmod 0755 /run/sshd
fi

# --- environment for SSH sessions and login shells --------------------------
# SSH sessions do not inherit the container environment. Export every service
# variable except the password (and shell bookkeeping) two ways: /etc/profile.d
# for login shells (ttyd, interactive ssh) and /etc/environment for PAM, which
# covers non-interactive ssh commands and IDE remotes. Anything added in
# Railway's Variables tab appears in the box after the next deploy.
: > /run/devbox-profile.sh
: > /run/devbox-environment
echo '# generated at boot by /usr/local/bin/entrypoint.sh; do not edit' >> /run/devbox-profile.sh
echo 'PATH=/home/dev/.local/bin:/home/dev/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /run/devbox-environment
while IFS= read -r -d '' entry; do
  name="${entry%%=*}"
  value="${entry#*=}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  case "$name" in
    SSH_PASSWORD|PASSWORD|AUTHORIZED_KEYS|HOME|PATH|PWD|OLDPWD|SHLVL|_|USER|LOGNAME|SHELL|TERM|HOSTNAME|DEBIAN_FRONTEND) continue;;
  esac
  printf 'export %s=%q\n' "$name" "$value" >> /run/devbox-profile.sh
  case "$value" in *$'\n'*) continue;; esac   # pam_env is line-based
  printf '%s=%s\n' "$name" "$value" >> /run/devbox-environment
done < <(env -0)
install -o root -g dev -m 0640 /run/devbox-profile.sh /etc/profile.d/10-railway-env.sh
install -o root -g dev -m 0640 /run/devbox-environment /etc/environment
rm -f /run/devbox-profile.sh /run/devbox-environment

if [ -n "${TZ:-}" ]; then
  if [ -f "/usr/share/zoneinfo/$TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
  else
    echo "devbox: TZ='$TZ' is not a zoneinfo name; keeping UTC" >&2
  fi
fi

# git over HTTPS uses GITHUB_TOKEN when it is set; gh reads the same variable.
if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --system credential.https://github.com.helper \
    '!f() { printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
else
  git config --system --unset credential.https://github.com.helper 2>/dev/null || true
fi

# --- nginx: $PORT -> ttyd on loopback, basic auth dev:$SSH_PASSWORD ---------
printf 'dev:%s\n' "$(openssl passwd -6 "$SSH_PASSWORD")" > /run/devbox.htpasswd
chown root:www-data /run/devbox.htpasswd
chmod 0640 /run/devbox.htpasswd

cat > /run/devbox-nginx.conf <<EOF
user www-data;
worker_processes 1;
pid /run/devbox-nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 256; }
http {
  access_log off;
  server_tokens off;
  map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
  server {
    listen 0.0.0.0:${PORT} default_server;
    server_name _;
    location = /healthz {
      proxy_pass http://127.0.0.1:${TTYD_PORT}/;
      proxy_http_version 1.1;
      proxy_set_header Host \$host;
      proxy_read_timeout 5s;
    }
    location / {
      auth_basic "dev box";
      auth_basic_user_file /run/devbox.htpasswd;
      proxy_pass http://127.0.0.1:${TTYD_PORT};
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_set_header Host \$host;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_read_timeout 1d;
      proxy_send_timeout 1d;
      proxy_buffering off;
    }
  }
}
EOF
nginx -t -q -c /run/devbox-nginx.conf

# --- start -----------------------------------------------------------------
# supervise NAME CMD...: run CMD in the background and respawn it whenever it
# exits. The supervisor's own PID goes into PIDS for shutdown.
supervise() {
  local name=$1; shift
  (
    child=
    trap '[ -n "$child" ] && kill "$child" 2>/dev/null; exit 0' TERM INT
    while :; do
      "$@" &
      child=$!
      wait "$child" && st=0 || st=$?
      echo "devbox: $name exited with status $st; restarting it in 2 s" >&2
      sleep 2
    done
  ) &
  PIDS+=("$!")
}

# sshd logs to stderr; a small filter mirrors each line to the container log
# and writes it syslog-shaped ("Mon DD HH:MM:SS host sshd[pid]: msg") into
# /run/devbox-sshd.log, which is the format fail2ban's sshd filter parses.
run_sshd() {
  # `sudo service ssh restart` starts a second sshd on :22; wait for it to go
  # rather than failing to bind every 2 s.
  while ss -Hltn 'sport = :22' | grep -q .; do sleep 10; done
  /usr/sbin/sshd -D -e 2>&1 | while IFS= read -r line; do
      printf 'sshd: %s\n' "$line" >&2
      printf '%s %s sshd[1]: %s\n' "$(date '+%b %e %H:%M:%S')" "${HOSTNAME:-devbox}" "$line" >> /run/devbox-sshd.log
    done
}

run_ttyd() {
  setpriv --reuid=dev --regid=dev --init-groups --reset-env \
    /usr/local/bin/ttyd -p "$TTYD_PORT" -i 127.0.0.1 -W \
      -t titleFixed="dev box" -t fontSize=14 -t disableLeaveAlert=true \
      bash -lc 'exec tmux new-session -A -s main'
}

PIDS=()
if [ "$SSH_ENABLED" = 1 ]; then
  : > /run/devbox-sshd.log; chmod 0640 /run/devbox-sshd.log
  supervise sshd run_sshd
  if iptables -w 2 -L INPUT -n >/dev/null 2>&1; then
    mkdir -p /run/fail2ban
    supervise fail2ban sh -c 'rm -f /run/fail2ban/fail2ban.sock; exec fail2ban-server -xf start >/dev/null 2>&1'
    BRUTE_FORCE="fail2ban (5 failures / 10 min -> 1 h ban) + sshd per-source throttling"
  else
    BRUTE_FORCE="sshd per-source throttling (no NET_ADMIN in this container, fail2ban not started)"
  fi
fi

supervise ttyd run_ttyd
supervise nginx nginx -c /run/devbox-nginx.conf -g 'daemon off;'

echo "devbox: ubuntu $(. /etc/os-release && echo "$VERSION_ID") | node $(node --version) | claude $(claude --version 2>/dev/null | head -n1)"
if [ "$SSH_ENABLED" = 1 ]; then
  if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
    echo "devbox: ssh dev@${RAILWAY_TCP_PROXY_DOMAIN} -p ${RAILWAY_TCP_PROXY_PORT}"
  else
    echo "devbox: sshd listens on 22; add a TCP proxy for port 22 under Settings -> Networking to reach it"
  fi
  echo "devbox: ssh brute-force protection: $BRUTE_FORCE"
else
  echo "devbox: SSH is off (DEVBOX_SSH=off); browser terminal only"
fi
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  echo "devbox: browser terminal https://${RAILWAY_PUBLIC_DOMAIN}/  (user dev)"
else
  echo "devbox: browser terminal on port ${PORT} (user dev)"
fi
echo "devbox: password = PASSWORD (or SSH_PASSWORD) in the service's Variables tab; /home/dev is on the volume"

# Bounded stop: TERM the supervisors and every other process (some helpers
# ignore TERM), give them a second, then KILL what is left and exit 0 well
# inside Railway's stop window.
shutdown() {
  trap '' TERM INT
  kill "${PIDS[@]}" 2>/dev/null || true
  kill -TERM -1 2>/dev/null || true
  sleep 1
  kill -KILL -1 2>/dev/null || true
  exit 0
}
trap shutdown TERM INT
while :; do wait || true; sleep 1; done
