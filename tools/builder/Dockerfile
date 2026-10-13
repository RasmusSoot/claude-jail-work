# Build sidecar for a stack jail: the Paketo builder image the stack names, plus helm and the loop.
# Built by tools/stack-jail.sh per stack (`jail-<stack>-builder`) from BUILDER_IMAGE in
# stacks/<stack>.conf. Runs in the jail's network namespace as the host UID with the same posture
# as the other sidecars (read-only root, no capabilities, no-new-privileges): the lifecycle needs
# no privilege, it is what `pack build` runs inside this very image. What the jail cannot do
# (push to a registry) the sidecar does, under a name allowlist, with a credential the jail never
# sees. See tools/builder/builder.sh for the request format and docs/security.md for the model.
ARG BUILDER_IMAGE=paketobuildpacks/builder-noble-java-tiny

# helm, fetched from its vendor over HTTPS and checked against the published sha256 — the same
# "latest at build time, rebuild to update" rule as the jail image (docs/security.md, accepted
# risks). HELM_VERSION=vX.Y.Z pins it.
FROM debian:trixie AS helm
ARG HELM_VERSION=latest
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN set -eu; arch=$(dpkg --print-architecture); v="$HELM_VERSION"; \
    [ "$v" != latest ] || v=$(curl -fsSL https://get.helm.sh/helm-latest-version); \
    f="helm-$v-linux-$arch.tar.gz"; \
    curl -fsSL -o "$f" "https://get.helm.sh/$f"; curl -fsSL -o "$f.sha256sum" "https://get.helm.sh/$f.sha256sum"; \
    sha256sum -c "$f.sha256sum"; tar -xzf "$f" "linux-$arch/helm"; \
    install -d /out && install -m 0755 "linux-$arch/helm" /out/helm && /out/helm version --short

# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE}
COPY --from=helm --chmod=0755 /out/helm /usr/local/bin/helm
COPY --chmod=0755 builder.sh /usr/local/bin/jail-builder
# Nothing below /cnb is touched: the lifecycle, buildpacks and run-image metadata are the
# builder's own. Scratch goes to /build/<request>/ and /tmp (tmpfs); the root stays read-only.
ENTRYPOINT ["/usr/local/bin/jail-builder"]
