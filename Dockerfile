FROM node:22-bookworm

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN apt-get update && \
    apt-get install -y --no-install-recommends zsh git jq curl gpg tini python3 sudo xz-utils ipmitool && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# tea — the Forgejo/Gitea CLI, the Forgejo counterpart to gh. No apt repo exists
# for it, so we pin a release binary and verify its sha256. Kept here (baked into
# the image, jail-wide) alongside gh on purpose: both are forge CLIs, not
# per-project tooling. Bump TEA_VERSION + TEA_SHA256 together (checksums at
# https://dl.gitea.com/tea/<ver>/tea-<ver>-linux-amd64.sha256).
ARG TEA_VERSION=0.14.1
ARG TEA_SHA256=3cf7c5d1c20808c9ba2efb9ac125cee10d969daf398e653ea2b33cde201ea317
RUN curl -fsSL "https://dl.gitea.com/tea/${TEA_VERSION}/tea-${TEA_VERSION}-linux-amd64" -o /usr/local/bin/tea && \
    echo "${TEA_SHA256}  /usr/local/bin/tea" | sha256sum -c - && \
    chmod 0755 /usr/local/bin/tea

RUN npm install -g @anthropic-ai/claude-code

# Remap the existing 'node' user/group to match the host UID/GID so files
# created in mounted volumes are owned by the host user. Also switch the
# login shell to zsh.
RUN usermod -u ${HOST_UID} -s /bin/zsh node && groupmod -g ${HOST_GID} node

# Passwordless sudo for 'node' so software can be apt-installed mid-session.
RUN echo 'node ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node && \
    visudo -cf /etc/sudoers.d/node

# Devbox (Jetify): declarative, Nix-backed toolchain shared with the host. Only the
# devbox binary is baked in — packages resolve from the host's /nix store, which is
# bind-mounted at runtime (see docker-compose.yml). The same per-project devbox.json
# then works identically in the jail and on the host. Run `devbox install` on the host
# to populate the shared store; the jail consumes it via `devbox shell`.
RUN curl -fsSL https://get.jetify.com/devbox | bash -s -- -f && \
    chmod 0755 /usr/local/bin/devbox
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"

# Nix multi-user build users. devbox's `print-dev-env` (run inside the jail) reads the
# host's bind-mounted /nix config, which sets build-users-group=nixbld; nix errors out
# unless that group exists *with members*. These users only satisfy that check — actual
# builds use the shared host store. Without this, `devbox run`/`devbox shell` fail in the jail.
RUN groupadd -r nixbld && \
    for i in 1 2 3 4; do \
      useradd -r -g nixbld -G nixbld -d /var/empty -s /usr/sbin/nologin -c "Nix build user $i" "nixbld$i"; \
    done

ENV SHELL=/bin/zsh

COPY tools/jail-entrypoint.sh /usr/local/bin/jail-entrypoint.sh
RUN chmod +x /usr/local/bin/jail-entrypoint.sh

USER node
WORKDIR /workspace

# tini is PID 1: reaps the backgrounded upload server and forwards signals to
# the whole group (-g) so both claude and the server stop cleanly.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/jail-entrypoint.sh"]
CMD ["claude"]
