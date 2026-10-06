FROM node:22-bookworm

ARG HOST_UID=1000
ARG HOST_GID=1000

# No sudo in this image on purpose: package installs belong in the Dockerfile or a devbox.json,
# and a container root remapped to the host UID would have host-root reach over the bind mounts.
RUN apt-get update && \
    apt-get install -y --no-install-recommends git jq curl gpg tini python3 xz-utils && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Remap the existing 'node' user/group to the host UID/GID so files created in bind mounts are
# owned by the host user. Login shell bash (also what the Bash tool runs).
RUN usermod -u ${HOST_UID} -s /bin/bash node && groupmod -g ${HOST_GID} node

# Devbox (Jetify): the binary is baked in; packages come from the jails' OWN Nix store below.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f && \
    chmod 0755 /usr/local/bin/devbox

# Jail-only Nix store. The host's /nix is NOT mounted: it is single-user, owned by the host UID,
# so a writable mount let any jail replace binaries the host later runs. Single-user Nix is
# installed here as node (pinned + checksummed); docker-compose.yml mounts the named volume
# `jail-nix` at /nix, which Docker seeds from this image layer on first use and every jail shares.
# No sandbox / build users: no root and no user namespaces in the container.
ARG NIX_VERSION=2.32.0
ARG NIX_INSTALL_SHA256=8e886d56d170aaac416cf2727d14e25e39bff92b7e0a2f6d12eee058f30717a9
RUN mkdir -m 0755 /nix /etc/nix && chown node:node /nix && \
    printf 'experimental-features = nix-command flakes\nsandbox = false\nbuild-users-group =\n' > /etc/nix/nix.conf
USER node
RUN curl -fsSL -o /tmp/nix-install "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" && \
    echo "${NIX_INSTALL_SHA256}  /tmp/nix-install" | sha256sum -c - && \
    sh /tmp/nix-install --no-daemon --no-channel-add --no-modify-profile --yes && \
    rm /tmp/nix-install
USER root
ENV PATH="/home/node/.nix-profile/bin:${PATH}"

# /workspace is container-local in a stack jail (only repo dirs are mounted into it) and must be
# writable by node without sudo — it used to be chowned at init.
RUN mkdir -p /workspace && chown node:node /workspace
ENV SHELL=/bin/bash

COPY tools/jail-entrypoint.sh /usr/local/bin/jail-entrypoint.sh
RUN chmod +x /usr/local/bin/jail-entrypoint.sh

USER node
WORKDIR /workspace

# tini is PID 1: reaps the backgrounded upload server and forwards signals to the whole group.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/jail-entrypoint.sh"]
CMD ["claude"]
