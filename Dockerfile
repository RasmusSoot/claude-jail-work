FROM node:22-bookworm

ARG HOST_UID=1000
ARG HOST_GID=1000

# No sudo in this image on purpose: package installs belong in the Dockerfile or a devbox.json,
# and a container root remapped to the host UID would have host-root reach over the bind mounts.
RUN apt-get update && \
    apt-get install -y --no-install-recommends zsh git jq curl gpg tini python3 xz-utils && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Remap the existing 'node' user/group to the host UID/GID so files created in bind mounts are
# owned by the host user. Login shell zsh.
RUN usermod -u ${HOST_UID} -s /bin/zsh node && groupmod -g ${HOST_GID} node

# Devbox (Jetify): only the binary is baked in — packages resolve from the host's /nix store,
# bind-mounted at runtime (docker-compose.yml). Run `devbox install` on the host to populate it.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f && \
    chmod 0755 /usr/local/bin/devbox
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"

# Nix multi-user build users: the host's bind-mounted /nix config sets build-users-group=nixbld
# and nix refuses to run unless that group exists with members. Builds still use the host store.
RUN groupadd -r nixbld && \
    for i in 1 2 3 4; do \
      useradd -r -g nixbld -G nixbld -d /var/empty -s /usr/sbin/nologin -c "Nix build user $i" "nixbld$i"; \
    done

# /workspace is container-local in a client jail (only repo dirs are mounted into it) and must be
# writable by node without sudo — it used to be chowned at init.
RUN mkdir -p /workspace && chown node:node /workspace
ENV SHELL=/bin/zsh

COPY tools/jail-entrypoint.sh /usr/local/bin/jail-entrypoint.sh
RUN chmod +x /usr/local/bin/jail-entrypoint.sh

USER node
WORKDIR /workspace

# tini is PID 1: reaps the backgrounded upload server and forwards signals to the whole group.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/jail-entrypoint.sh"]
CMD ["claude"]
