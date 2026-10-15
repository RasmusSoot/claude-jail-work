#!/usr/bin/env bash
# kind-stack — HOST-side lifecycle of a stack's local kind cluster and registry, from the stack conf.
#
#   kind-stack.sh <stack> up        create or repair: registry (with its push credential), cluster, containerd registry config,
#                                   the stack namespace (Pod Security label), workbench SA + RoleBinding,
#                                   and, if ARGO_APPS is set, Argo CD with one Application per chart,
#                                   plus the KIND_ADDONS Applications in project `platform`
#   kind-stack.sh <stack> status    what exists, what the launcher's gates will say
#   kind-stack.sh <stack> ui        the Argo CD UI on host loopback (a port-forward: works on Linux,
#                                   Mac and Windows alike; Ctrl-C ends it), with the admin login
#   kind-stack.sh <stack> grafana   the same for Grafana, when KIND_ADDONS lists kube-prometheus-stack
#   kind-stack.sh <stack> registry-config   print the registry policy `up` renders (no secret in it)
#   kind-stack.sh <stack> argo-policy       print the Argo CD RBAC policy `up` renders (the launcher's
#                                   gate requires the cluster's to equal it, line for line)
#   kind-stack.sh <stack> addons-render     print the `platform` AppProject `up` applies for KIND_ADDONS (JSON)
#   kind-stack.sh <stack> down      delete the cluster; the registry stays (it is the layer cache)
#   kind-stack.sh <stack> purge     down + remove the registry container and its storage dir
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
#   KIND_ADDONS       cluster-scoped add-ons the jail cannot install, space-separated names (optional;
#                     needs ARGO_APPS, since they are Argo CD Applications): each is addons/<name>.yaml
#                     in THIS repo, applied by `up` into AppProject `platform`, which allows exactly the
#                     chart repos and namespaces those files declare and every cluster-scoped kind.
#                     Removing a name does not uninstall it. GRAFANA_UI_PORT (default 3000) is the
#                     host loopback port `grafana` forwards to (kube-prometheus-stack).
#   BUILD_NAMES       the names the build sidecar may push (tools/stack-jail.sh); here they are also
#                     the registry's push policy: the push user may write exactly <name>, <name>-cache
#                     and charts/<name> for each, nothing else. Re-run `up` after changing them.
# The registry is per stack: container `jail-<stack>-registry` (Zot, REGISTRY_IMAGE), reachable
# as jail-<stack>-registry:5000 on the kind network — which is
# what the launcher's BUILD_REGISTRY defaults to; it runs as the host user with no capability, its
# storage in ~/claude/jail/.registry-<stack>-data/. Anyone may pull; pushes need the credential
# REGISTRY_PUSH_USER/PASSWORD from ~/claude/jail/.env.<stack>, which `up` generates and writes there
# when absent and which the launcher hands to the build sidecar only. Its bcrypt hash and the policy
# live in ~/claude/jail/.registry-<stack>/ (host-only). Idempotent; re-run after changing the conf.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/host-tools.sh
. "$HERE/tools/host-tools.sh"                        # kind/kubectl pinned by this repo's devbox.json
STACK="${1:-}"; ACTION="${2:-status}"
[ -n "$STACK" ] || { echo "usage: kind-stack.sh <stack> up|status|ui|grafana|registry-config|argo-policy|addons-render|down|purge" >&2; exit 2; }
CONF="${KIND_STACK_CONF:-$HERE/stacks/$STACK.conf}"             # the override is for tests/ only
readonly ADDONS_DIR="${KIND_ADDONS_DIR:-$HERE/addons}"         # likewise; set before the conf and readonly, so a conf cannot move it
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
KIND_ADDONS="${KIND_ADDONS:-}"; GRAFANA_UI_PORT="${GRAFANA_UI_PORT:-3000}"
GRAFANA_NS=monitoring; GRAFANA_SECRET=grafana-admin               # what addons/kube-prometheus-stack.yaml declares
REG="jail-$STACK-registry"; REG_VOL="jail-registry-$STACK"; CTX="kind-$KIND_CLUSTER"   # REG_VOL: the old root-owned volume, removed when met
REG_DATA="$JAIL_HOME/.registry-$STACK-data"                       # layers and charts, owned by the host user (the registry runs as that user)
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
  mkdir -p "$REG_DATA"; chmod 700 "$REG_DATA"
  if docker container inspect "$REG" >/dev/null 2>&1; then
    have=$(docker container inspect -f '{{.Config.Image}}' "$REG")
    if [ "$have" != "$REGISTRY_IMAGE" ]; then
      # A different registry program: its storage layout does not carry over. Storage is a cache
      # (layers, charts the sidecar rebuilds in minutes), so recreate rather than migrate.
      docker rm -f "$REG" >/dev/null; rm -rf "$REG_DATA"; mkdir -p "$REG_DATA"; chmod 700 "$REG_DATA"
      ok "registry: $REG was $have — recreated as $REGISTRY_IMAGE with fresh storage (cache and charts dropped; rebuild and push again)"
    elif [ "$(docker container inspect -f '{{.Config.User}}|{{.HostConfig.CapAdd}}' "$REG" 2>/dev/null)" != "$(id -u):$(id -g)|[]" ]; then
      # Run flags belong to the container, not the image: one made by an older version of this
      # script (root, a capability, a root-owned volume) is recreated as the host user on the data dir.
      docker rm -f "$REG" >/dev/null; ok "registry: $REG recreated as the host user with no capability (storage moves to $REG_DATA; cache and charts dropped; rebuild and push again)"
    fi
  fi
  docker volume rm "$REG_VOL" >/dev/null 2>&1 || true            # the old root-owned volume, once nothing uses it
  if ! docker container inspect "$REG" >/dev/null 2>&1; then
    local pub=(); [ -z "$REGISTRY_PORT" ] || pub=(-p "127.0.0.1:$REGISTRY_PORT:5000")
    # As the host user, with every capability dropped: it reads the host-owned, mode-700 config
    # dir as its owner, and writes storage the owner owns. Not root with DAC_READ_SEARCH — under
    # Docker's default seccomp profile that capability re-enables open_by_handle_at, i.e. a
    # compromised registry reading any file on the host filesystem behind the bind mount.
    docker run -d --restart=always --name "$REG" --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
      -v "$REG_DATA:/var/lib/registry" -v "$REG_DIR:/etc/zot:ro" ${pub[@]+"${pub[@]}"} "$REGISTRY_IMAGE" >/dev/null
    created=1; ok "registry: created $REG (storage $REG_DATA${REGISTRY_PORT:+, host 127.0.0.1:$REGISTRY_PORT}; pull anonymous, push as $PUSH_USER)"
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
      # config_path: containerd reads the per-registry hosts.toml files registry_wire writes only
      # when told where they are (newer containerd defaults to this dir, 2.1 in current kindest
      # images does not; kind's own local-registry docs set it explicitly).
      # The admission patch comes in both kubeadm API versions: kind applies a patch to the
      # generated document whose kind AND apiVersion it names and drops the other (pkg/internal/
      # patch), and which version kind generates follows the NODE IMAGE (0.32: v1beta4 from
      # v1.36, v1beta3 below), so KIND_NODE_IMAGE decides, not the kind binary. Patches are RFC
      # 7386 merges: the v1beta4 list replaces kind's whole list, so it repeats what kind puts
      # there (runtime-config, empty by default). NodeRestriction is kubeadm's default; this key
      # replaces the default, so it is kept.
      cat <<EOT
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    apiVersion: kubeadm.k8s.io/v1beta3
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        enable-admission-plugins: NodeRestriction,DenyServiceExternalIPs
  - |
    apiVersion: kubeadm.k8s.io/v1beta4
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
      - name: runtime-config
        value: ""
      - name: enable-admission-plugins
        value: NodeRestriction,DenyServiceExternalIPs
EOT
      if [ -n "$KIND_HTTP_PORT" ]; then
        # labels: kind's own node field (it renders the kubelet node-labels arg in whichever kubeadm
        # version it generates); a kubeletExtraArgs patch would hit the same map/list split as above.
        cat <<EOT
  labels:
    ingress-ready: "true"
  extraPortMappings:
  - { containerPort: 80, hostPort: $KIND_HTTP_PORT, listenAddress: "127.0.0.1", protocol: TCP }
EOT
      fi
    } | kind create cluster --name "$KIND_CLUSTER" ${img[@]+"${img[@]}"} --config=-
  fi
}

# containerd on every node: the registry by its kind-network name (what the charts reference and
# the sidecar pushes to) and, if published, as localhost:<port> (what the kind docs assume). Plain
# HTTP, through hosts.toml files under certs.d, which containerd reads only where config_path says
# so (set at create time above; added here on nodes made before that).
registry_wire() {
  local n host
  for n in $(nodes); do
    # A node made before the create-time patch above: add the setting and restart containerd
    # (pods keep running; the kubelet reconnects). Without it the hosts.toml below is never read
    # and the node speaks HTTPS to the plain-HTTP registry.
    if ! docker exec "$n" grep -q 'config_path' /etc/containerd/config.toml; then
      # Under the registry table if the file has one (a second header for the same table is a TOML
      # error and containerd would not come back), else appended with its header.
      docker exec -i "$n" sh -s <<'EOS'
f=/etc/containerd/config.toml; t='[plugins."io.containerd.grpc.v1.cri".registry]'
if grep -qxF "$t" "$f"; then
  awk -v t="$t" '{ print } $0 == t { print "  config_path = \"/etc/containerd/certs.d\"" }' "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
else
  printf '\n%s\n  config_path = "/etc/containerd/certs.d"\n' "$t" >> "$f"
fi
EOS
      docker exec "$n" systemctl restart containerd
      ok "registry: $n's containerd now reads /etc/containerd/certs.d (setting added, containerd restarted)"
    fi
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
# by a namespaced RoleBinding, cannot patch/delete any namespace, create namespaces or reach the
# kubelet, holds nothing beyond get/list/watch where there is no Pod Security label, and no shell
# subresource in any labelled namespace but this one. Nothing more: everything else the stack
# deploys is the lab's, inside this namespace.
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

# Cluster add-ons (KIND_ADDONS): what a namespace-admin jail cannot install — CRDs, ClusterRoles,
# webhooks — installed by the host and kept in sync by the same Argo CD, in a project of their own.
# The file is what the host applies with cluster-admin and the project is built from it, so before
# anything is applied each listed file must say what the conf says: one Application document named
# <name> in argocd, project platform, a public https chart repo (never the stack registry, which
# the jail pushes to: a jail-pushed chart in this project would be cluster-admin), an exact version,
# a namespace of its own, the chart's values inline. Block-style YAML only, and strictly: every line
# is blank, a comment, a list item or a plain `key:` / `key: value`, or the file is refused — so
# `kind : List`, `<<:` merges, anchors and aliases, quoted keys, tabs, block scalars and any `---`
# (a leading one included) cannot make kubectl read a key this parse did not see; the required
# paths must each occur exactly once.
addon_fields() { # <file> → "dotted.path=value" per mapping key (lists and comments skipped)
  awk '
    /^---/ { print "!multidoc"; next }
    /^ *["\047]/ { print "!quotedkey"; next }
    /\t/ { print "!unparsed " NR; next }
    /^[[:space:]]*(#|$)/ { next }
    { match($0, /^ */); ind = RLENGTH; line = substr($0, ind + 1)
      if (line ~ /^-( |$)/) { if (line ~ /^- *[&*!|>]/) print "!unparsed " NR; next }
      if (!match(line, /^[A-Za-z0-9_.\/-]+:( |$)/)) { print "!unparsed " NR; next }
      key = substr(line, 1, RLENGTH - 1); sub(/:$/, "", key); sub(/: $/, "", key); val = substr(line, RLENGTH + 1)
      if (val ~ /^[[:space:]]*[&*!|>]/) { print "!unparsed " NR; next }
      while (n > 0 && indent[n] >= ind) n--
      n++; indent[n] = ind; name[n] = key; p = name[1]; for (i = 2; i <= n; i++) p = p "." name[i]
      sub(/[[:space:]]+#.*$/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); gsub(/^["\047]|["\047]$/, "", val)
      print p "=" val }' "$1"
}
addon_field() { # <fields> <path> → its value; fails unless the path occurs exactly once
  printf '%s\n' "$1" | awk -v k="$2" '{ i = index($0, "="); if (substr($0, 1, i - 1) == k) { c++; v = substr($0, i + 1) } }
                                       END { if (c != 1) exit 1; print v }'
}
addons_check() { # sets ADDON_REPOS ADDON_NSES (deduplicated) from the files KIND_ADDONS names; exit 2 on any mismatch
  local n f fields v repo ns
  ADDON_REPOS=(); ADDON_NSES=()
  # `platform` as a stack would have addons_project apply over the stack's own project (blacklist gone, cluster `*`).
  [ -z "$KIND_ADDONS" ] || [ "$STACK" != platform ] || { fail "FATAL: a stack named platform cannot have KIND_ADDONS — the name is the addons' AppProject"; exit 2; }
  for n in $KIND_ADDONS; do
    [[ "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { fail "FATAL: KIND_ADDONS: '$n' is not an addon name"; exit 2; }
    case " $ARGO_APPS " in *" $n "*) fail "FATAL: $n is in both KIND_ADDONS and ARGO_APPS — the two Applications would overwrite each other"; exit 2 ;; esac
    f="$ADDONS_DIR/$n.yaml"
    [ -f "$f" ] || { fail "FATAL: KIND_ADDONS: $n — no $f"; exit 2; }
    fields=$(addon_fields "$f")
    bad() { fail "FATAL: addons/$n.yaml: $*"; exit 2; }
    printf '%s\n' "$fields" | grep -qx '!multidoc' && bad "a --- line (one YAML document, no separator)"
    printf '%s\n' "$fields" | grep -qx '!quotedkey' && bad "a quoted key (plain keys only, so a duplicate cannot slip past a check)"
    v=$(printf '%s\n' "$fields" | sed -n 's/^!unparsed //p' | paste -sd, -)
    [ -z "$v" ] || bad "line(s) $v are not a plain key, list item or comment (no 'key :', merges, anchors, aliases, tags, block scalars or tabs)"
    [ "$(addon_field "$fields" apiVersion)" = argoproj.io/v1alpha1 ] && [ "$(addon_field "$fields" kind)" = Application ] \
      || bad "not one argoproj.io/v1alpha1 Application"
    [ "$(addon_field "$fields" metadata.name)" = "$n" ] || bad "metadata.name is not $n"
    [ "$(addon_field "$fields" metadata.namespace)" = "$ARGO_NS" ] || bad "metadata.namespace is not $ARGO_NS"
    [ "$(addon_field "$fields" spec.project)" = platform ] || bad "spec.project is not platform"
    printf '%s\n' "$fields" | grep -q '^spec\.sources[.=]' && bad "spec.sources (multi-source) — one spec.source only"
    printf '%s\n' "$fields" | grep -q '^spec\.source\.\(path\|plugin\)[.=]' && bad "spec.source.path or .plugin — a Helm chart only"
    printf '%s\n' "$fields" | grep -q '^spec\.source\.helm\.\(valueFiles\|fileParameters\)[.=]' && bad "spec.source.helm.valueFiles or .fileParameters — values inline only"
    addon_field "$fields" spec.source.chart >/dev/null || bad "no single spec.source.chart"
    repo=$(addon_field "$fields" spec.source.repoURL) || bad "no single spec.source.repoURL"
    [[ "$repo" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$ ]] || bad "spec.source.repoURL '$repo' is not a public https chart repo"
    v=$(addon_field "$fields" spec.source.targetRevision) || bad "no spec.source.targetRevision"
    [[ "$v" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || bad "spec.source.targetRevision '$v' is not a pinned version"
    ns=$(addon_field "$fields" spec.destination.namespace) || bad "no single spec.destination.namespace"
    [[ "$ns" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || bad "spec.destination.namespace '$ns' is not a namespace name"
    case "$ns" in "$ARGO_NS"|"$KIND_NS"|default|kube-system|kube-public|kube-node-lease) bad "spec.destination.namespace '$ns' is not a namespace of its own" ;; esac
    [ "$(addon_field "$fields" spec.destination.server)" = https://kubernetes.default.svc ] || bad "spec.destination.server is not https://kubernetes.default.svc"
    if [ "$n" = kube-prometheus-stack ]; then   # what `grafana` and the Secret below assume
      [ "$ns" = "$GRAFANA_NS" ] || bad "spec.destination.namespace is not $GRAFANA_NS"
      [ "$(addon_field "$fields" spec.source.helm.valuesObject.grafana.admin.existingSecret)" = "$GRAFANA_SECRET" ] \
        || bad "grafana.admin.existingSecret is not $GRAFANA_SECRET"
    fi
    unset -f bad
    case " ${ADDON_REPOS[*]-} " in *" $repo "*) ;; *) ADDON_REPOS+=("$repo") ;; esac
    case " ${ADDON_NSES[*]-} " in *" $ns "*) ;; *) ADDON_NSES+=("$ns") ;; esac
  done
}
# The project: exactly those repos and namespaces, every cluster-scoped kind (the point of an addon)
# and every namespaced one. Nothing in a jail is granted on it — argo_policy_csv names $STACK/* only,
# so the jail sees platform apps through its read Role and cannot sync them. JSON: kubectl takes it.
addons_project() {
  jq -n --arg ns "$ARGO_NS" --arg repos "${ADDON_REPOS[*]}" --arg nses "${ADDON_NSES[*]}" '
    {apiVersion: "argoproj.io/v1alpha1", kind: "AppProject",
     metadata: {name: "platform", namespace: $ns},
     spec: {description: "host-installed cluster add-ons (tools/kind-stack.sh, addons/): public charts, pinned, cluster-scoped kinds allowed",
            sourceRepos: ($repos | split(" ")),
            destinations: [$nses | split(" ")[] | {server: "https://kubernetes.default.svc", namespace: .}],
            clusterResourceWhitelist: [{group: "*", kind: "*"}]}}'
}
# Grafana's admin Secret (the addon file names it as admin.existingSecret): made once, kept across
# re-runs. The chart's own would be re-randomised on every Argo render and restart Grafana each time.
grafana_secret() {
  local pass
  kc create namespace "$GRAFANA_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n "$GRAFANA_NS" get secret "$GRAFANA_SECRET" >/dev/null 2>&1 && return
  pass=$(head -c 30 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
  kc apply -f - >/dev/null <<EOT
apiVersion: v1
kind: Secret
metadata: { name: $GRAFANA_SECRET, namespace: $GRAFANA_NS }
stringData:
  admin-user: admin
  admin-password: $pass
EOT
  ok "addons: Grafana admin password generated (Secret $GRAFANA_SECRET in $GRAFANA_NS; kind-stack.sh $STACK grafana prints it)"
}
addons_up() {
  local n
  if [ -z "$KIND_ADDONS" ]; then   # a conf edit never uninstalls: what an earlier run applied stays until deleted by hand
    ! kc -n "$ARGO_NS" get appproject platform >/dev/null 2>&1 \
      || info "addons: none in KIND_ADDONS; project platform and its apps from an earlier run left in place"
    return
  fi
  addons_project | kc apply -f - >/dev/null
  case " $KIND_ADDONS " in *" kube-prometheus-stack "*) grafana_secret ;; esac
  for n in $KIND_ADDONS; do
    kc apply -f "$ADDONS_DIR/$n.yaml" >/dev/null
    kc -n "$ARGO_NS" annotate applications.argoproj.io "$n" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  done
  ok "addons: [$KIND_ADDONS] in project platform (sources [${ADDON_REPOS[*]}], namespaces [${ADDON_NSES[*]}]); nothing in the jail is granted on it"
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
          kc -n "$ARGO_NS" get applications.argoproj.io -o custom-columns='  app:.metadata.name,project:.spec.project,sync:.status.sync.status,health:.status.health.status,revision:.status.sync.revision' 2>/dev/null || true
          for app in $ARGO_APPS $KIND_ADDONS; do   # why a sync is Unknown: the controller's conditions (repo unreachable, no version matched, …)
            kc -n "$ARGO_NS" get applications.argoproj.io "$app" -o jsonpath='{range .status.conditions[*]}{"  '"$app"': "}{.type}{": "}{.message}{"\n"}{end}' 2>/dev/null || true
          done
          if [ -n "$KIND_ADDONS" ]; then   # the platform apps are in the table above (project platform)
            kc -n "$ARGO_NS" get appproject platform >/dev/null 2>&1 && echo "addons: project platform, apps [$KIND_ADDONS]" \
              || echo "addons: MISSING (KIND_ADDONS is set) — run: kind-stack.sh $STACK up"
          fi
        else
          echo "argocd: MISSING (ARGO_APPS is set) — run: kind-stack.sh $STACK up"
        fi
      elif [ -n "$KIND_ADDONS" ]; then
        echo "addons: KIND_ADDONS is set but ARGO_APPS is empty — no Argo CD, so no addons; set ARGO_APPS"
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
  up)     # Addons are Argo CD Applications, and Argo CD comes only with ARGO_APPS; checked before anything is made.
          [ -z "$KIND_ADDONS" ] || [ -n "$ARGO_APPS" ] \
            || { fail "FATAL: KIND_ADDONS is set but ARGO_APPS is empty — addons need Argo CD, which is installed only with ARGO_APPS"; exit 2; }
          addons_check
          registry_up; cluster_up; registry_wire; stack_rbac; argo_up; addons_up; echo; status ;;
  status) status ;;
  registry-config) registry_config "${REGISTRY_PUSH_USER:-<push user>}" ;;
  argo-policy) argo_policy_csv ;;
  addons-render) addons_check
          if [ -n "$KIND_ADDONS" ]; then addons_project; else info "addons: no KIND_ADDONS — no platform project" >&2; fi ;;
  grafana) case " $KIND_ADDONS " in *" kube-prometheus-stack "*) ;;
             *) echo "kube-prometheus-stack is not in KIND_ADDONS in stacks/$STACK.conf — no Grafana on this cluster" >&2; exit 1 ;; esac
          # As `ui`: the host's kubeconfig forwards, loopback only, a disposable cluster's admin login.
          ok "grafana: http://127.0.0.1:$GRAFANA_UI_PORT — user admin, password: $(kc -n "$GRAFANA_NS" get secret "$GRAFANA_SECRET" -o jsonpath='{.data.admin-password}' | base64 -d)"
          echo "  Ctrl-C ends the forward. GRAFANA_UI_PORT in the conf or the environment picks another port."
          exec kubectl --context "$CTX" -n "$GRAFANA_NS" port-forward --address 127.0.0.1 svc/kube-prometheus-stack-grafana "$GRAFANA_UI_PORT:80" ;;
  ui)     [ -n "$ARGO_APPS" ] || { echo "no ARGO_APPS in stacks/$STACK.conf — no Argo CD on this cluster" >&2; exit 1; }
          # The host's kubeconfig does the forwarding, so no node IP is needed (Docker Desktop
          # cannot reach one). Admin on a disposable cluster's Argo CD, reachable on loopback only:
          # harmless class, so the password is printed rather than hidden behind another command.
          ok "argocd UI: https://127.0.0.1:$ARGO_UI_PORT (self-signed certificate) — user admin, password: $(kc -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
          echo "  Ctrl-C ends the forward. ARGO_UI_PORT in the conf or the environment picks another port."
          exec kubectl --context "$CTX" -n "$ARGO_NS" port-forward --address 127.0.0.1 svc/argocd-server "$ARGO_UI_PORT:443" ;;
  down)   cluster_exists && kind delete cluster --name "$KIND_CLUSTER"; info "registry $REG kept (layer cache); 'purge' removes it" ;;
  purge)  cluster_exists && kind delete cluster --name "$KIND_CLUSTER"
          docker rm -f "$REG" >/dev/null 2>&1 || true; docker volume rm "$REG_VOL" >/dev/null 2>&1 || true; rm -rf "$REG_DIR" "$REG_DATA"
          ok "removed cluster $KIND_CLUSTER, registry $REG, its storage $REG_DATA and $REG_DIR (the credential stays in $ENV_FILE)" ;;
  *) echo "usage: kind-stack.sh <stack> up|status|ui|grafana|registry-config|argo-policy|addons-render|down|purge" >&2; exit 2 ;;
esac
