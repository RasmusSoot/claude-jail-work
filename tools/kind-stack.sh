#!/usr/bin/env bash
# kind-stack — HOST-side lifecycle of a stack's local kind cluster and registry, from the stack conf.
#
#   kind-stack.sh <stack> up        create or repair: registry (with its push credential), cluster, containerd registry config,
#                                   the stack namespace (Pod Security label), workbench SA + RoleBinding,
#                                   and, if ARGO_APPS is set, Argo CD with one Application per chart
#   kind-stack.sh <stack> status    what exists, what the launcher's gates will say
#   kind-stack.sh <stack> ui        the Argo CD UI on host loopback (a port-forward: works on Linux,
#                                   Mac and Windows alike; Ctrl-C ends it), with the admin login
#   kind-stack.sh <stack> registry-config   print the registry policy `up` renders (no secret in it)
#   kind-stack.sh <stack> argo-policy       print the Argo CD RBAC policy `up` renders (the launcher's
#                                   gate requires the cluster's to equal it, line for line)
#   kind-stack.sh <stack> down      delete the cluster; the registry stays (it is the layer cache)
#   kind-stack.sh <stack> purge     down + remove the registry container and its volume
#
# Why here and not in a stack's lab repo: the host runs this with the host's Docker and kubeconfig,
# and a stack jail can write every file in its lab repo. The rule is "the host runs nothing from a
# stack's tree" (docs/security.md): cluster lifecycle and everything the launcher's gates require
# of a cluster (namespace label, SA, RoleBinding, the Argo account) are the mechanism's, driven by
# stacks/<stack>.conf:
#   KIND_CLUSTER      cluster name (context kind-<name>); required
#   KIND_NS, KIND_SA  namespace and ServiceAccount the launcher mints for (defaults: <stack>, <stack>-workbench)
#   KIND_NET          docker network the nodes are on (default kind — kind's own, shared by clusters)
#   REGISTRY_PORT     host loopback port for the registry (optional: without it the registry is
#                     reachable only on the kind network, i.e. from nodes, sidecars and jails)
#   KIND_HTTP_PORT    host loopback port mapped to the control-plane's :80 for an ingress (optional)
#   KIND_NODE_IMAGE   kindest/node tag to pin (optional; default = this kind's default)
#   ARGO_APPS         Argo CD Applications to create, one per chart name in the stack registry
#                     (optional; no Argo CD without it). ARGO_VERSION (default below) is the release
#                     installed from its upstream manifest; ARGO_NODEPORT (default 30443) is where the
#                     API server listens on the nodes — the jail reaches it as <cluster>-control-plane:<port>.
#                     ARGO_UI_PORT (default 8443) is the host loopback port `ui` forwards to it.
#   BUILD_NAMES       the names the build sidecar may push (tools/stack-jail.sh); here they are also
#                     the registry's push policy: the push user may write exactly <name>, <name>-cache
#                     and charts/<name> for each, nothing else. Re-run `up` after changing them.
# The registry is per stack: container `jail-<stack>-registry` (Zot, REGISTRY_IMAGE), volume
# `jail-registry-<stack>`, reachable as jail-<stack>-registry:5000 on the kind network — which is
# what the launcher's BUILD_REGISTRY defaults to. Anyone may pull; pushes need the credential
# REGISTRY_PUSH_USER/PASSWORD from ~/claude/jail/.env.<stack>, which `up` generates and writes there
# when absent and which the launcher hands to the build sidecar only. Its bcrypt hash and the policy
# live in ~/claude/jail/.registry-<stack>/ (host-only). Idempotent; re-run after changing the conf.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/host-tools.sh
. "$HERE/tools/host-tools.sh"                        # kind/kubectl pinned by this repo's devbox.json
STACK="${1:-}"; ACTION="${2:-status}"
[ -n "$STACK" ] || { echo "usage: kind-stack.sh <stack> up|status|ui|registry-config|down|purge" >&2; exit 2; }
CONF="${KIND_STACK_CONF:-$HERE/stacks/$STACK.conf}"             # the override is for tests/ only
[ -f "$CONF" ] || { fail "FATAL: $CONF missing"; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
: "${KIND_CLUSTER:?stacks/$STACK.conf must set KIND_CLUSTER}"
KIND_NS="${KIND_NS:-$STACK}"; KIND_SA="${KIND_SA:-$STACK-workbench}"; KIND_NET="${KIND_NET:-kind}"
REGISTRY_PORT="${REGISTRY_PORT:-}"; KIND_HTTP_PORT="${KIND_HTTP_PORT:-}"; KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-ghcr.io/project-zot/zot:v2.1.22}"   # the combined image: registry + its web UI
HTPASSWD_IMAGE="${HTPASSWD_IMAGE:-httpd:2.4-alpine}"               # only for `htpasswd -B` (bcrypt is all Zot accepts)
BUILD_NAMES="${BUILD_NAMES:-}"
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"; ENV_FILE="$JAIL_HOME/.env.$STACK"
REG_DIR="$JAIL_HOME/.registry-$STACK"                             # policy + bcrypt hash, mounted read-only into the registry
ARGO_APPS="${ARGO_APPS:-}"; ARGO_VERSION="${ARGO_VERSION:-v3.5.5}"; ARGO_NODEPORT="${ARGO_NODEPORT:-30443}"
ARGO_NS=argocd; ARGO_ACCOUNT="$STACK-jail"                   # the account the launcher mints session tokens for
ARGO_UI_PORT="${ARGO_UI_PORT:-8443}"
REG="jail-$STACK-registry"; REG_VOL="jail-registry-$STACK"; CTX="kind-$KIND_CLUSTER"
kc() { kubectl --context "$CTX" "$@"; }

running() { [ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; }
nodes() { kind get nodes --name "$KIND_CLUSTER" 2>/dev/null; }

# The push credential: REGISTRY_PUSH_USER/PASSWORD in the stack's env file (the launcher reads the
# same two lines for the build sidecar). Generated here when either is missing — a human-invented
# password for a loopback registry adds nothing, and the hash below needs the value anyway.
registry_credential() { # sets PUSH_USER PUSH_PASS
  [ -f "$ENV_FILE" ] || { fail "FATAL: $ENV_FILE missing — tools/stack-env.sh $STACK first"; exit 2; }
  local pair
  # shellcheck source=/dev/null
  pair=$( . "$ENV_FILE" 2>/dev/null; printf '%s\n%s\n' "${REGISTRY_PUSH_USER:-}" "${REGISTRY_PUSH_PASSWORD:-}" )
  PUSH_USER="${pair%%$'\n'*}"; PUSH_PASS="${pair#*$'\n'}"; PUSH_PASS="${PUSH_PASS%%$'\n'*}"
  if [ -z "$PUSH_USER" ] || [ -z "$PUSH_PASS" ]; then
    PUSH_USER="$STACK-push"; PUSH_PASS=$(head -c 30 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    local k v
    for k in REGISTRY_PUSH_USER REGISTRY_PUSH_PASSWORD; do
      [ "$k" = REGISTRY_PUSH_USER ] && v="$PUSH_USER" || v="$PUSH_PASS"
      if grep -q "^$k=" "$ENV_FILE"; then sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"; else printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"; fi
    done
    ok "registry: generated push credential for user $PUSH_USER, written to $ENV_FILE (the sidecar gets it from there)"
  fi
}

# Zot's policy, from BUILD_NAMES: anyone reads anything (nodes, Argo, the jail); the push user
# creates/updates exactly the names the sidecar may push — the same allowlist, enforced by the
# registry itself, so the credential is worth those names and no others even if lifted.
# compat docker2s2: the CNB lifecycle exports Docker schema-2 manifests (no OCI option on registry
# export), which Zot refuses with MANIFEST_INVALID unless told to accept them.
registry_config() { # <push user> → JSON on stdout
  local n repos=()
  for n in $BUILD_NAMES; do repos+=("$n" "$n-cache" "charts/$n"); done
  jq -n --arg user "$1" '
    {distSpecVersion: "1.1.1",
     storage: {rootDirectory: "/var/lib/registry", gc: true, dedupe: true},
     http: {address: "0.0.0.0", port: "5000",
            compat: ["docker2s2"],
            auth: {htpasswd: {path: "/etc/zot/htpasswd"}},
            accessControl: {repositories:
              ({"**": {anonymousPolicy: ["read"], defaultPolicy: ["read"]}}
               + ([$ARGS.positional[] | {key: ., value: {anonymousPolicy: ["read"], defaultPolicy: ["read"],
                                                         policies: [{users: [$user], actions: ["read", "create", "update"]}]}}]
                  | from_entries))}},
     log: {level: "info"}}' --args ${repos[@]+"${repos[@]}"}
}

registry_up() {
  local created=0 changed=0 have src
  registry_credential
  mkdir -p "$REG_DIR"; chmod 700 "$REG_DIR"
  # Rendered in place (the directory is the mount, so new inodes are seen); restart only on change.
  registry_config "$PUSH_USER" > "$REG_DIR/config.json.new"
  cmp -s "$REG_DIR/config.json.new" "$REG_DIR/config.json" 2>/dev/null || changed=1
  mv "$REG_DIR/config.json.new" "$REG_DIR/config.json"
  src=$(printf '%s:%s' "$PUSH_USER" "$PUSH_PASS" | sha256sum | cut -c1-64)   # which credential the hash was made from
  if [ "$(cat "$REG_DIR/htpasswd.src" 2>/dev/null)" != "$src" ] || [ ! -s "$REG_DIR/htpasswd" ]; then
    ( umask 077; printf '%s' "$PUSH_PASS" | docker run --rm -i "$HTPASSWD_IMAGE" htpasswd -niB "$PUSH_USER" > "$REG_DIR/htpasswd" ) \
      || { fail "FATAL: could not hash the push credential with $HTPASSWD_IMAGE"; exit 2; }
    printf '%s' "$src" > "$REG_DIR/htpasswd.src"; changed=1
  fi
  unset PUSH_PASS
  if docker container inspect "$REG" >/dev/null 2>&1; then
    have=$(docker container inspect -f '{{.Config.Image}}' "$REG")
    # Run flags belong to the container, not the image: one made without DAC_READ_SEARCH (an older
    # version of this script, with or without --cap-drop) is recreated on the same volume.
    if ! docker container inspect -f '{{.HostConfig.CapAdd}}' "$REG" 2>/dev/null | grep -q DAC_READ_SEARCH; then
      docker rm -f "$REG" >/dev/null; ok "registry: $REG recreated with its current run flags (volume kept)"
    elif [ "$have" != "$REGISTRY_IMAGE" ]; then
      # A different registry program: its storage layout does not carry over. The volume is a
      # cache (layers, charts the sidecar rebuilds in minutes), so recreate rather than migrate.
      docker rm -f "$REG" >/dev/null; docker volume rm "$REG_VOL" >/dev/null 2>&1 || true
      ok "registry: $REG was $have — recreated as $REGISTRY_IMAGE with a fresh volume (cache and charts dropped; rebuild and push again)"
    fi
  fi
  if ! docker container inspect "$REG" >/dev/null 2>&1; then
    local pub=(); [ -z "$REGISTRY_PORT" ] || pub=(-p "127.0.0.1:$REGISTRY_PORT:5000")
    # Zot runs as root; with every capability dropped that root cannot enter the host-owned,
    # mode-700 config dir or read the mode-600 htpasswd. DAC_READ_SEARCH is the read-side bypass
    # only (no writes, no chown): the dir and the hash stay private on the host.
    docker run -d --restart=always --name "$REG" --cap-drop ALL --cap-add DAC_READ_SEARCH --security-opt no-new-privileges \
      -v "$REG_VOL:/var/lib/registry" -v "$REG_DIR:/etc/zot:ro" ${pub[@]+"${pub[@]}"} "$REGISTRY_IMAGE" >/dev/null
    created=1; ok "registry: created $REG (volume $REG_VOL${REGISTRY_PORT:+, host 127.0.0.1:$REGISTRY_PORT}; pull anonymous, push as $PUSH_USER)"
  elif ! running "$REG"; then
    docker start "$REG" >/dev/null; ok "registry: started $REG"
  elif [ "$changed" = 1 ]; then
    docker restart "$REG" >/dev/null; ok "registry: policy or credential changed — restarted $REG"
  fi
  sleep 2
  if ! running "$REG"; then
    fail "FATAL: $REG is not running. It said:"; docker logs "$REG" 2>&1 | tail -5 | sed 's/^/    /' >&2; exit 2
  fi
  [ "$created" = 1 ] || true
}

# Whether the front is real: an anonymous blob upload must be refused. Only checkable from the
# host when the registry is published on loopback; the launcher repeats this before each session.
registry_probe() { # prints one line
  local n code
  n="${BUILD_NAMES%% *}"; [ -n "$n" ] || n=probe
  [ -n "$REGISTRY_PORT" ] || { echo "registry push policy: unverified from the host (no REGISTRY_PORT)"; return; }
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "http://127.0.0.1:$REGISTRY_PORT/v2/$n/blobs/uploads/" 2>/dev/null) || code="000"
  case "$code" in
    401) echo "registry push policy: anonymous push refused (401) — the sidecar's allowlist is a boundary" ;;
    000) echo "registry push policy: no answer on 127.0.0.1:$REGISTRY_PORT" ;;
    *)   warn "registry push policy: anonymous push got HTTP $code, not 401 — the allowlist is NOT a boundary" ;;
  esac
}

cluster_up() {
  if cluster_exists; then
    local n started=""
    for n in $(nodes); do running "$n" || { docker start "$n" >/dev/null; started="$started $n"; }; done
    [ -z "$started" ] || { ok "cluster: started stopped nodes:$started"; sleep 5; }
    ok "cluster: $KIND_CLUSTER exists"
  else
    ok "cluster: creating $KIND_CLUSTER"
    local img=(); [ -z "$KIND_NODE_IMAGE" ] || img=(--image "$KIND_NODE_IMAGE")
    {
      # DenyServiceExternalIPs: a namespace admin could otherwise give a Service the node's own
      # address and have kube-proxy hand it the launcher's traffic to Argo CD (CVE-2020-8554).
      cat <<EOT
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:                                  # kubeadm v1beta3 map form (what kind 0.29 generates; v1beta4 would take a list)
        enable-admission-plugins: NodeRestriction,DenyServiceExternalIPs   # NodeRestriction is kubeadm's default: this key replaces it, so it is kept
EOT
      if [ -n "$KIND_HTTP_PORT" ]; then
        cat <<EOT
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - { containerPort: 80, hostPort: $KIND_HTTP_PORT, listenAddress: "127.0.0.1", protocol: TCP }
EOT
      fi
    } | kind create cluster --name "$KIND_CLUSTER" ${img[@]+"${img[@]}"} --config=-
  fi
}

# containerd on every node: the registry by its kind-network name (what the charts reference and
# the sidecar pushes to) and, if published, as localhost:<port> (what the kind docs assume). Plain
# HTTP; the certs.d config dir is containerd's default in current kindest/node images.
registry_wire() {
  local n host
  for n in $(nodes); do
    for host in "$REG:5000" ${REGISTRY_PORT:+"localhost:$REGISTRY_PORT"}; do
      docker exec "$n" mkdir -p "/etc/containerd/certs.d/$host"
      printf '[host."http://%s:5000"]\n' "$REG" | docker exec -i "$n" cp /dev/stdin "/etc/containerd/certs.d/$host/hosts.toml"
    done
  done
  # A container that is (re)starting has no network sandbox yet, and `network connect` then fails
  # with "network sandbox for container … not found": wait for the registry to run, then retry.
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do running "$REG" && break; sleep 1; done
  running "$REG" || { fail "registry: $REG is not running (docker logs --tail 20 $REG)"; return 1; }
  if ! docker network inspect "$KIND_NET" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qw "$REG"; then
    local err=""
    for _ in 1 2 3 4 5; do
      err=$(docker network connect "$KIND_NET" "$REG" 2>&1) && break
      # A failed attempt (the sandbox race above) can leave a stale endpoint behind that is not
      # listed under the network's containers but blocks the next connect: drop it and retry.
      case "$err" in *"already exists"*|*"endpoint with name"*) docker network disconnect -f "$KIND_NET" "$REG" >/dev/null 2>&1 || true ;; esac
      sleep 2
    done
    docker network inspect "$KIND_NET" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | grep -qw "$REG" \
      || { fail "registry: could not join $REG to network $KIND_NET. docker said: ${err:-nothing}"; return 1; }
    ok "registry: joined network $KIND_NET"
  fi
  if [ -n "$REGISTRY_PORT" ]; then
    kc apply -f - >/dev/null <<EOT
apiVersion: v1
kind: ConfigMap
metadata: { name: local-registry-hosting, namespace: kube-public }
data:
  localRegistryHosting.v1: |
    host: "localhost:$REGISTRY_PORT"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOT
  fi
  ok "registry: nodes pull from $REG:5000${REGISTRY_PORT:+ and localhost:$REGISTRY_PORT}"
}

# What the launcher's kind gate checks before minting (tools/stack-jail.sh kind_psa_gate): the
# namespace enforces Pod Security baseline, and the SA, bound to the built-in `admin` ClusterRole
# by a namespaced RoleBinding, cannot patch/delete the namespace, create namespaces, or create
# pods elsewhere. Nothing more: everything else the stack deploys is the lab's, inside this namespace.
stack_rbac() {
  kc apply -f - >/dev/null <<EOT
apiVersion: v1
kind: Namespace
metadata:
  name: $KIND_NS
  labels: { pod-security.kubernetes.io/enforce: baseline }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: $KIND_SA, namespace: $KIND_NS }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: $KIND_SA-admin, namespace: $KIND_NS }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: admin }
subjects: [{ kind: ServiceAccount, name: $KIND_SA, namespace: $KIND_NS }]
EOT
  ok "rbac: namespace $KIND_NS (Pod Security baseline), SA $KIND_SA = admin in it"
}

# Argo CD, the deploy half of the agent loop: the jail pushes a chart through the build sidecar
# and runs `argocd app sync`; nothing in that loop is a denied verb. From the conf, generically:
#   - the upstream install manifest at ARGO_VERSION, API server on a NodePort (TLS, its own cert);
#   - a repository entry for the stack registry's charts, OCI over plain HTTP: `insecureOCIForceHttp`
#     is what makes helm pull with --plain-http, and `insecure` must stay false — helm drops
#     --plain-http when --insecure-skip-tls-verify is set too (found the hard way, 2026-10-12);
#   - an AppProject = this registry → this namespace, namespaced resources only, and no Role or
#     RoleBinding among them (that, not the launcher's token, is what keeps a sync from touching
#     anything cluster-scoped or from binding the workbench SA higher than the kind gate allows);
#   - one Application per ARGO_APPS entry: chart <name>, any released version (`*`), release name
#     = app name, `values-kind.yaml` from the chart if it ships one, auto-sync + prune + self-heal;
#   - a local account <stack>-jail (apiKey only, no UI login) whose whole policy is get + sync +
#     logs on this project; the launcher mints an 8h token for it per session (tools/stack-jail.sh);
#   - a read Role in argocd for the workbench SA, so `kubectl -n argocd get app` works from the jail;
#   - a 30s reconciliation timeout, so a pushed chart is noticed within a kind-sized wait.
argo_policy_csv() { # the whole of argocd-rbac-cm policy.csv: get + sync + logs on the project, nothing else
  printf '%s\n' \
      "p, role:$ARGO_ACCOUNT, applications, get, $STACK/*, allow" \
      "p, role:$ARGO_ACCOUNT, applications, sync, $STACK/*, allow" \
      "p, role:$ARGO_ACCOUNT, logs, get, $STACK/*, allow" \
      "p, role:$ARGO_ACCOUNT, projects, get, $STACK, allow" \
      "g, $ARGO_ACCOUNT, role:$ARGO_ACCOUNT"
}
argo_up() {
  local app have
  [ -n "$ARGO_APPS" ] || { info "argocd: no ARGO_APPS in stacks/$STACK.conf — not installed"; return; }
  have=$(kc -n "$ARGO_NS" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [ "${have##*:}" != "$ARGO_VERSION" ]; then
    ok "argocd: installing $ARGO_VERSION${have:+ (over ${have##*:})} from the upstream manifest"
    kc create namespace "$ARGO_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
    kc apply -n "$ARGO_NS" --server-side --force-conflicts \
      -f "https://raw.githubusercontent.com/argoproj/argo-cd/$ARGO_VERSION/manifests/install.yaml" >/dev/null
  else
    ok "argocd: $ARGO_VERSION present"
  fi
  kc -n "$ARGO_NS" patch svc argocd-server --type merge \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"https\",\"port\":443,\"targetPort\":8080,\"nodePort\":$ARGO_NODEPORT}]}}" >/dev/null
  kc -n "$ARGO_NS" patch cm argocd-cm --type merge \
    -p "{\"data\":{\"accounts.$ARGO_ACCOUNT\":\"apiKey\",\"timeout.reconciliation\":\"30s\",\"timeout.reconciliation.jitter\":\"10s\"}}" >/dev/null
  # Both ConfigMaps come from the install manifest (server-side applied), so they are patched, not
  # re-applied; Argo CD watches them, no restart needed.
  kc -n "$ARGO_NS" patch cm argocd-rbac-cm --type merge -p "$(jq -n --arg csv "$(argo_policy_csv)" '{data: {"policy.default": "", "policy.csv": $csv}}')" >/dev/null
  kc apply -f - >/dev/null <<EOT
apiVersion: v1
kind: Secret
metadata: { name: $STACK-registry, namespace: $ARGO_NS, labels: { argocd.argoproj.io/secret-type: repository } }
stringData:
  name: $STACK-registry
  type: helm
  url: $REG:5000/charts
  enableOCI: "true"
  insecure: "false"
  insecureOCIForceHttp: "true"
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: { name: $STACK, namespace: $ARGO_NS }
spec:
  description: "$STACK — charts from the stack registry into namespace $KIND_NS, nothing cluster-scoped"
  sourceRepos: ["$REG:5000/charts"]
  destinations: [{ server: https://kubernetes.default.svc, namespace: $KIND_NS }]
  clusterResourceWhitelist: []
  namespaceResourceBlacklist:           # a pushed chart must not bind the workbench SA higher: a RoleBinding to
  - { group: rbac.authorization.k8s.io, kind: Role }          # cluster-admin inside the namespace would authorise patching
  - { group: rbac.authorization.k8s.io, kind: RoleBinding }   # the namespace, i.e. dropping the Pod Security label
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: $KIND_SA-argocd-read, namespace: $ARGO_NS }
rules:
- apiGroups: [argoproj.io]
  resources: [applications, appprojects]
  verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: $KIND_SA-argocd-read, namespace: $ARGO_NS }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: $KIND_SA-argocd-read }
subjects: [{ kind: ServiceAccount, name: $KIND_SA, namespace: $KIND_NS }]
EOT
  # The install's `default` project allows every source, destination and kind; nothing here uses
  # it, and nothing in a jail can create an Application, but an empty project costs nothing. The
  # server creates that project at its first start, not the manifest: on a fresh install, wait for it.
  local _
  for _ in $(seq 1 60); do kc -n "$ARGO_NS" get appproject default >/dev/null 2>&1 && break; sleep 2; done
  kc -n "$ARGO_NS" get appproject default >/dev/null 2>&1 \
    || { fail "argocd: the server has not created the default AppProject after 120s — is argocd-server starting? (kubectl --context $CTX -n $ARGO_NS get pods)"; exit 2; }
  kc -n "$ARGO_NS" patch appproject default --type merge -p '{"spec":{"sourceRepos":[],"destinations":[],"clusterResourceWhitelist":[]}}' >/dev/null
  for app in $ARGO_APPS; do
    kc apply -f - >/dev/null <<EOT
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: $app, namespace: $ARGO_NS }   # no finalizer: the cluster is disposable, and deleting the Application should not take the namespace's workload with it
spec:
  project: $STACK
  source:
    repoURL: $REG:5000/charts
    chart: $app
    targetRevision: "*"
    helm:
      releaseName: $app
      valueFiles: [values-kind.yaml]
      ignoreMissingValueFiles: true
  destination: { server: https://kubernetes.default.svc, namespace: $KIND_NS }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
EOT
    # A hard refresh: the repo-server pauses generation for minutes after repeated failures and
    # serves the cached error, so a repaired Secret would not show until then.
    kc -n "$ARGO_NS" annotate applications.argoproj.io "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  done
  for app in argocd-server argocd-repo-server argocd-application-controller; do
    kc -n "$ARGO_NS" rollout status "deploy/$app" --timeout=300s >/dev/null 2>&1 \
      || kc -n "$ARGO_NS" rollout status "statefulset/$app" --timeout=300s >/dev/null 2>&1 \
      || warn "argocd: $app not ready after 300s — the launcher will mint no argocd token until it is"
  done
  ok "argocd: $ARGO_VERSION on $KIND_CLUSTER-control-plane:$ARGO_NODEPORT; apps [$ARGO_APPS] from $REG:5000/charts into $KIND_NS; account $ARGO_ACCOUNT = get+sync on project $STACK"
}

status() {
  local psa app
  if cluster_exists; then
    if running "$KIND_CLUSTER-control-plane"; then
      echo "cluster $KIND_CLUSTER: running (context $CTX)"
      psa=$(kc get ns "$KIND_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null) \
        && echo "namespace $KIND_NS: present, pod-security enforce='${psa:-<unset>}'" || echo "namespace $KIND_NS: MISSING — run: kind-stack.sh $STACK up"
      kc -n "$KIND_NS" get sa "$KIND_SA" >/dev/null 2>&1 && echo "serviceaccount $KIND_SA: present" || echo "serviceaccount $KIND_SA: MISSING — run: kind-stack.sh $STACK up"
      if [ -n "$ARGO_APPS" ]; then
        if kc -n "$ARGO_NS" get deploy argocd-server >/dev/null 2>&1; then
          echo "argocd: $(kc -n "$ARGO_NS" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://') on $KIND_CLUSTER-control-plane:$ARGO_NODEPORT, account $ARGO_ACCOUNT$(kc -n "$ARGO_NS" get cm argocd-cm -o jsonpath="{.data.accounts\.$ARGO_ACCOUNT}" 2>/dev/null | grep -q apiKey || echo ' MISSING — run: kind-stack.sh '"$STACK"' up')"
          kc -n "$ARGO_NS" get applications.argoproj.io -o custom-columns='  app:.metadata.name,sync:.status.sync.status,health:.status.health.status,revision:.status.sync.revision' 2>/dev/null || true
          for app in $ARGO_APPS; do   # why a sync is Unknown: the controller's conditions (repo unreachable, no version matched, …)
            kc -n "$ARGO_NS" get applications.argoproj.io "$app" -o jsonpath='{range .status.conditions[*]}{"  '"$app"': "}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null || true
          done
        else
          echo "argocd: MISSING (ARGO_APPS is set) — run: kind-stack.sh $STACK up"
        fi
      fi
    else
      echo "cluster $KIND_CLUSTER: exists but NOT running — run: kind-stack.sh $STACK up"
    fi
  else
    echo "cluster $KIND_CLUSTER: absent — run: kind-stack.sh $STACK up"
  fi
  if running "$REG"; then echo "registry $REG: running${REGISTRY_PORT:+ (host 127.0.0.1:$REGISTRY_PORT, UI there too)}, push names [$BUILD_NAMES] (+ -cache, charts/)"; registry_probe
  elif docker container inspect "$REG" >/dev/null 2>&1; then echo "registry $REG: stopped"
  else echo "registry $REG: absent"; fi
}

case "$ACTION" in
  up)     registry_up; cluster_up; registry_wire; stack_rbac; argo_up; echo; status ;;
  status) status ;;
  registry-config) registry_config "${REGISTRY_PUSH_USER:-<push user>}" ;;
  argo-policy) argo_policy_csv ;;
  ui)     [ -n "$ARGO_APPS" ] || { echo "no ARGO_APPS in stacks/$STACK.conf — no Argo CD on this cluster" >&2; exit 1; }
          # The host's kubeconfig does the forwarding, so no node IP is needed (Docker Desktop
          # cannot reach one). Admin on a disposable cluster's Argo CD, reachable on loopback only:
          # harmless class, so the password is printed rather than hidden behind another command.
          ok "argocd UI: https://127.0.0.1:$ARGO_UI_PORT (self-signed certificate) — user admin, password: $(kc -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
          echo "  Ctrl-C ends the forward. ARGO_UI_PORT in the conf or the environment picks another port."
          exec kubectl --context "$CTX" -n "$ARGO_NS" port-forward --address 127.0.0.1 svc/argocd-server "$ARGO_UI_PORT:443" ;;
  down)   cluster_exists && kind delete cluster --name "$KIND_CLUSTER"; info "registry $REG kept (layer cache); 'purge' removes it" ;;
  purge)  cluster_exists && kind delete cluster --name "$KIND_CLUSTER"
          docker rm -f "$REG" >/dev/null 2>&1 || true; docker volume rm "$REG_VOL" >/dev/null 2>&1 || true; rm -rf "$REG_DIR"
          ok "removed cluster $KIND_CLUSTER, registry $REG, volume $REG_VOL and $REG_DIR (the credential stays in $ENV_FILE)" ;;
  *) echo "usage: kind-stack.sh <stack> up|status|ui|registry-config|argo-policy|down|purge" >&2; exit 2 ;;
esac
