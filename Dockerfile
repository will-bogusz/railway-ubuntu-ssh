# syntax=docker/dockerfile:1
#
# Ubuntu 24.04 dev box for Railway: sshd behind Railway's TCP proxy (fail2ban
# when the container has NET_ADMIN, sshd per-source throttling otherwise), a
# browser terminal (ttyd behind nginx basic auth) on $PORT, /home/dev on a
# volume, Claude Code preinstalled. DEVBOX_SSH=off runs the browser terminal
# only (the "Ubuntu Web Terminal" template). Everything is pinned; bump the ARGs and
# rebuild. See README.md for the runtime contract.

# ubuntu:24.04 multi-arch index digest, resolved 2026-09-20 from Docker Hub.
ARG UBUNTU_DIGEST=sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

# ---------------------------------------------------------------------------
# fetch: download and verify every non-apt artefact. Nothing from this stage
# but the verified files reaches the runtime image.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04@${UBUNTU_DIGEST} AS fetch

ARG NODE_VERSION=24.21.0
ARG NODE_SHA256=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
ARG TTYD_VERSION=1.7.7
ARG TTYD_SHA256=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
ARG GH_VERSION=2.101.0
ARG GH_SHA256=f876a3b87bf67c94f773d17becca4dc7340b056dab901473a9260ee2a73e237b

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /fetch
RUN set -eu; \
    curl -fsSLo node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  node.tar.xz" | sha256sum -c -; \
    mkdir -p node && tar -xJf node.tar.xz -C node --strip-components=1; \
    rm node.tar.xz node/CHANGELOG.md node/README.md node/LICENSE; \
    curl -fsSLo ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64"; \
    echo "${TTYD_SHA256}  ttyd" | sha256sum -c -; \
    chmod 0755 ttyd; \
    curl -fsSLo gh.deb "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.deb"; \
    echo "${GH_SHA256}  gh.deb" | sha256sum -c -

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ubuntu:24.04@${UBUNTU_DIGEST}

ARG CLAUDE_CODE_VERSION=2.1.278

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    DISABLE_AUTOUPDATER=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server openssh-client sudo nginx-light openssl fail2ban iptables \
      ca-certificates curl wget gnupg git git-lfs \
      build-essential pkg-config \
      python3 python3-pip python3-venv \
      tmux vim nano less htop jq ripgrep tree file rsync unzip zip xz-utils \
      tzdata locales procps iproute2 iputils-ping dnsutils net-tools \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /etc/ssh/authorized_keys.d \
 && rm -f /etc/nginx/sites-enabled/default

COPY --from=fetch /fetch/node /usr/local
COPY --from=fetch /fetch/ttyd /usr/local/bin/ttyd
COPY --from=fetch /fetch/gh.deb /tmp/gh.deb
RUN dpkg -i /tmp/gh.deb && rm /tmp/gh.deb
# Claude Code, exact version, system-wide so a volume mounted over /home/dev can
# never shadow or lose it. Users update into ~/.local/bin (see profile.d).
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force \
 && claude --version

# Non-root login user. The base image ships `ubuntu` at uid 1000; free that uid
# so files on the volume keep a stable owner across rebuilds.
RUN userdel -r ubuntu \
 && useradd --uid 1000 --user-group --create-home --shell /bin/bash dev \
 && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
 && chmod 0440 /etc/sudoers.d/dev

COPY sshd_config /etc/ssh/sshd_config.d/10-railway.conf
COPY fail2ban.local /etc/fail2ban/jail.d/devbox.conf
# Debian's default jail file forces backend=systemd and nftables; there is no
# journald here.
RUN rm -f /etc/fail2ban/jail.d/defaults-debian.conf
COPY profile.d/20-devbox.sh /etc/profile.d/20-devbox.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
 && chmod 0644 /etc/ssh/sshd_config.d/10-railway.conf /etc/profile.d/20-devbox.sh /etc/fail2ban/jail.d/devbox.conf

EXPOSE 22 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
