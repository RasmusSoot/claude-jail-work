FROM debian:trixie

ARG HOST_UID=1000
ARG HOST_GID=1000

# Only what the jail itself needs. Project tooling (node, kubectl, gh, JDKs, …) comes from each
# repo's devbox.json, not from here. No sudo on purpose: package installs belong here or in a
# devbox.json, and a container root remapped to the host UID would have host-root reach over the
# bind mounts.
#   git              Claude, the init's credential store, Nix flakes — needed before any devbox
#   python3          upload server + its token (stdlib only)
#   jq               tools/statusline.sh (every render, every jail)
#   tini             PID 1 with -g: reaps the backgrounded upload server, forwards signals
#   curl, xz-utils   Nix / devbox / Claude installers; curl also at runtime
#   ca-certificates  every HTTPS call
#   procps           ps/kill/top for debugging sessions
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates git python3 jq tini curl xz-utils procps && \
    rm -rf /var/lib/apt/lists/*

# The 'claude' user, with the host UID/GID so files created in bind mounts are owned by the host
# user. Login shell bash (also what the Bash tool runs).
# macOS hosts have GID 20 (staff), which Debian already uses (dialout): reuse an existing group.
RUN (getent group ${HOST_GID} >/dev/null || groupadd -g ${HOST_GID} claude) && \
    useradd -u ${HOST_UID} -g ${HOST_GID} -m -s /bin/bash claude
ENV LANG=C.UTF-8 SHELL=/bin/bash

# Devbox (Jetify): the binary is baked in; packages come from the jails' OWN Nix store below.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f && \
    chmod 0755 /usr/local/bin/devbox

# Jail-only Nix store. The host's /nix is NOT mounted: it is single-user, owned by the host UID,
# so a writable mount let any jail replace binaries the host later runs. Single-user Nix is
# installed here as claude (pinned + checksummed); docker-compose.yml mounts the named volume
# `jail-nix` at /nix, which Docker seeds from this image layer on first use and every jail shares.
# No sandbox / build users: no root and no user namespaces in the container.
ARG NIX_VERSION=2.32.0
ARG NIX_INSTALL_SHA256=8e886d56d170aaac416cf2727d14e25e39bff92b7e0a2f6d12eee058f30717a9
RUN mkdir -m 0755 /nix /etc/nix && chown claude: /nix && \
    printf 'experimental-features = nix-command flakes\nsandbox = false\nbuild-users-group =\n' > /etc/nix/nix.conf

# /workspace is container-local in a stack jail (only repo dirs are mounted into it) and must be
# writable by claude without sudo.
RUN mkdir -p /workspace && chown claude: /workspace

COPY tools/jail-entrypoint.sh /usr/local/bin/jail-entrypoint.sh
RUN chmod +x /usr/local/bin/jail-entrypoint.sh

USER claude
RUN curl -fsSL -o /tmp/nix-install "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" && \
    echo "${NIX_INSTALL_SHA256}  /tmp/nix-install" | sha256sum -c - && \
    sh /tmp/nix-install --no-daemon --no-channel-add --no-modify-profile --yes && \
    rm /tmp/nix-install

# Claude Code, native build (no node needed): the installer checks the binary's checksum and puts
# it under ~/.local, which is not a mount, so it lives in the image. Latest at build time; a
# rebuild is the update, so the in-container auto-updater is off. The download cache under
# ~/.claude is dropped — that path is a bind mount at runtime.
RUN curl -fsSL -o /tmp/claude-install.sh https://claude.ai/install.sh && \
    bash /tmp/claude-install.sh && \
    rm -rf /tmp/claude-install.sh /home/claude/.claude/downloads
ENV PATH="/home/claude/.local/bin:/home/claude/.nix-profile/bin:${PATH}" \
    DISABLE_AUTOUPDATER=1

WORKDIR /workspace

# tini is PID 1: reaps the backgrounded upload server and forwards signals to the whole group.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/jail-entrypoint.sh"]
CMD ["claude"]
