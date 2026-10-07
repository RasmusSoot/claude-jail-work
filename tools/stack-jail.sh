#!/usr/bin/env bash
# stack-jail — host-side launcher for a per-stack jail (the credential airlock).
#
#   stack-jail.sh <stack> [--login]
#
# One jail per stack (a client's project, e.g. SiVa). What a stack IS comes from two files:
#   stacks/<stack>.conf          committed, generic: repos, primary dir, kind cluster, upload port,
#                                 READS = other stacks whose repo dirs are mounted READ-ONLY under
#                                 /reads/<stack>/<repo> (no tokens, no state of theirs; same client only)
#   $JAIL_HOME/.env.<stack>       gitignored: tokens + client FACTS (dev context, CIDR, GitLab host)
# Nothing client-derived may live in this repo — only in the env file (see CLAUDE.md).
#
# Boundaries are tokens + git; everything else is scenery:
#   - git: a fork-scoped GitHub token (resource owner = the trust-domain org, never the upstream),
#     a GitLab deploy token on a personal fork inside the client's GitLab, a read-only GitLab token
#     for fetching upstream. No token in a jail can write to an upstream repo.
#   - kubectl: TWO kubeconfig FILES, minted here per launch from the host credential, 8h:
#     kind.yaml = namespace-admin workbench SA on the local kind cluster (plain `kubectl`);
#     dev.yaml  = READ-ONLY SA on the client dev cluster, reachable only through tools/kdev,
#     and only installed after impersonation proves it cannot mutate or read secrets.
#   - filesystem: only $JAIL_HOME/<stack>/<repo> dirs are mounted. No ~/.kube, no ~/.ssh,
#     no Docker socket.
# Pushes are human (`! git push` or from the host) under the managed policy; the launcher never
# passes a permission-bypass flag. JAIL_CLAUDE_FLAGS exists for the day an exception is granted.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"           # this repo (the mechanism)
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"         # per-stack workspaces live here
STACK="${1:-}"; shift || true
LOGIN=0; [ "${1:-}" = "--login" ] && LOGIN=1
[ -n "$STACK" ] || { echo "usage: stack-jail.sh <stack> [--login]" >&2; exit 2; }

CONF="$HERE/stacks/$STACK.conf"
[ -f "$CONF" ] || { echo "FATAL: $CONF missing — add a stacks/<stack>.conf (see stacks/siva.conf)" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
: "${REPOS:?stacks/$STACK.conf must set REPOS}" "${PRIMARY:?must set PRIMARY}" "${UPLOAD_PORT:?must set UPLOAD_PORT}"
KIND_CLUSTER="${KIND_CLUSTER-$STACK}"               # conf may set KIND_CLUSTER="" = no kind for this stack
KIND_NET="${KIND_NET:-kind}"                        # docker network the kind nodes sit on
KIND_NS="${KIND_NS:-$STACK}"
KIND_SA="${KIND_SA:-$STACK-workbench}"

ENV_FILE="$JAIL_HOME/.env.$STACK"
STATE_DIR="$JAIL_HOME/.claude-data-$STACK"
CLAUDE_JSON="$JAIL_HOME/.claude-data-$STACK.json"
SHARED_CREDS="$JAIL_HOME/.claude-data/.credentials.json"   # login once via `jail-main`

mkdir -p "$STATE_DIR" "$JAIL_HOME/$STACK"
[ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
for r in $REPOS; do
  [ -d "$JAIL_HOME/$STACK/$r" ] || echo "⚠ $JAIL_HOME/$STACK/$r missing — clone it first (upstream fetch-only, origin = your fork)" >&2
done
# READ-ONLY views of other stacks: "<stack>:<repo>" pairs, resolved from each stack's own conf.
READ_PAIRS=""
for rs in ${READS:-}; do
  [ "$rs" != "$STACK" ] || continue
  [ -f "$HERE/stacks/$rs.conf" ] || { echo "⚠ READS: stacks/$rs.conf missing — skipping $rs" >&2; continue; }
  for r in $(. "$HERE/stacks/$rs.conf" && echo "$REPOS"); do
    [ -d "$JAIL_HOME/$rs/$r" ] && READ_PAIRS="$READ_PAIRS $rs:$r" || echo "⚠ READS: $JAIL_HOME/$rs/$r missing — skipping" >&2
  done
done

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOT
# $STACK jail — tokens + client FACTS. Gitignored; never copy values into any repo.
# GitHub: fine-grained PAT, resource owner = your trust-domain org, All repositories,
#   Contents R/W + Metadata, NO Pull requests. Reaches only the forks.
GH_TOKEN=
# Client GitLab (optional). READ token: personal PAT with read_repository only.
# WRITE: a deploy token with write_repository on YOUR personal fork inside the client's GitLab.
GITLAB_HOST=
GITLAB_READ_TOKEN=
GITLAB_FORK_PATH=            # e.g. group/you/iac-fork  (the path the deploy token is scoped to)
GITLAB_DEPLOY_USER=
GITLAB_DEPLOY_TOKEN=
# Client dev cluster (optional): HOST kubeconfig context + the read-only SA to mint from.
DEV_KUBE_CONTEXT=
DEV_KUBE_NS=
DEV_KUBE_SA=
EOT
  chmod 600 "$ENV_FILE"
  echo "→ created $ENV_FILE — fill it in, then re-run. Continuing without git/dev credentials." >&2
fi
set -a; . "$ENV_FILE"; set +a

# Bootstrap the per-stack Claude config from the login jail's solved state (onboarding, theme)
# — once; per-stack overrides then stick. statusLine is pinned on EVERY launch: it lives in this
# repo's project settings, which a stack jail never sees, and the script is tools/ (mounted ro).
python3 - "$JAIL_HOME/.claude-data/settings.json" "$STATE_DIR/settings.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
if os.path.exists(dst): s = json.load(open(dst))
elif os.path.exists(src): s = json.load(open(src))
else: s = {}
s["statusLine"] = {"type": "command", "command": "/workspace/tools/statusline.sh", "padding": 1}
json.dump(s, open(dst, "w"), indent=2)
PY
TRUST_DIRS=""; for r in $REPOS; do TRUST_DIRS="$TRUST_DIRS /workspace/$r"; done
python3 - "$CLAUDE_JSON" "$JAIL_HOME/.claude-data.json" $TRUST_DIRS <<'PY'
import json, os, sys
target, main_path, dirs = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open(target)); main = json.load(open(main_path)) if os.path.exists(main_path) else {}
for k in ("hasCompletedOnboarding", "lastOnboardingVersion", "theme"):
    if k not in d and main.get(k) is not None: d[k] = main[k]
p = d.setdefault("projects", {})
for x in dirs:
    e = p.setdefault(x, {}); e.setdefault("hasTrustDialogAccepted", True); e.setdefault("hasCompletedProjectOnboarding", True)
json.dump(d, open(target, "w"), indent=2)
PY

ERR_DIR=$(mktemp -d); trap 'rm -rf "$ERR_DIR"' EXIT          # mint stderr; no fixed /tmp names (cleanup() takes over later)
# ── token gates shared by both mints ────────────────────────────────────────────────────────────
is_jwt()  { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; }
jwt_sub() { # decode the JWT payload locally (base64url + padding) and print .sub; never prints the token
  local p; p=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  printf '%s' "$p" | base64 -d 2>/dev/null | jq -r '.sub // empty'
}

# ── kind: namespace-admin workbench SA, 8h, server = in-network control-plane name ──────────────
STACK_KUBE_TOKEN="" STACK_KUBE_SERVER="" STACK_KUBE_CA=""
if [ -z "$KIND_CLUSTER" ]; then
  echo "→ kind: none declared for $STACK — plain kubectl unavailable this session"
elif kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  if tok=$(kubectl --context "kind-$KIND_CLUSTER" -n "$KIND_NS" create token "$KIND_SA" --duration=8h 2>"$ERR_DIR/kind-mint.err" | tr -d '[:space:]'); then
    if is_jwt "$tok" && [ "$(jwt_sub "$tok")" = "system:serviceaccount:$KIND_NS:$KIND_SA" ]; then
      STACK_KUBE_TOKEN="$tok"
      _ikc=$(mktemp); kind get kubeconfig --internal --name "$KIND_CLUSTER" > "$_ikc"
      STACK_KUBE_SERVER=$(kubectl --kubeconfig "$_ikc" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
      STACK_KUBE_CA=$(kubectl --kubeconfig "$_ikc" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
      rm -f "$_ikc"
      echo "→ kind: minted 8h token for $KIND_SA@$KIND_NS ($STACK_KUBE_SERVER)"
    else
      echo "⚠ kind: minted token failed the shape/subject gate — continuing without kind kubectl" >&2
    fi
  else
    echo "⚠ kind: could not mint token for $KIND_SA@$KIND_NS (create the SA + RoleBinding in the lab repo). kubectl said:" >&2
    sed 's/^/    /' "$ERR_DIR/kind-mint.err" >&2
  fi
else
  echo "⚠ kind cluster '$KIND_CLUSTER' not found — continuing without kind kubectl" >&2
fi

# ── client dev: READ-ONLY SA, proven by impersonation BEFORE minting, 8h ────────────────────────
STACK_DEVKUBE_TOKEN="" STACK_DEVKUBE_SERVER="" STACK_DEVKUBE_CA=""
if [ -n "${DEV_KUBE_CONTEXT:-}" ] && [ -n "${DEV_KUBE_NS:-}" ] && [ -n "${DEV_KUBE_SA:-}" ]; then
  k() { kubectl --context "$DEV_KUBE_CONTEXT" "$@"; }
  as="system:serviceaccount:$DEV_KUBE_NS:$DEV_KUBE_SA"; ok=1
  # The SA's whole rule list (its namespace + everything cluster-scoped it inherits), not a few
  # spot checks: any verb outside get/list/watch, any non-resource write, or any secrets access
  # (list/watch return secret data too) refuses the mint. Unparseable output also refuses.
  if ! perms=$(k auth can-i --list -n "$DEV_KUBE_NS" --as="$as" 2>"$ERR_DIR/dev-perms.err"); then
    echo "ABORT dev: could not list $DEV_KUBE_SA permissions — dev credential NOT installed" >&2; sed 's/^/    /' "$ERR_DIR/dev-perms.err" >&2; ok=0
  else
    # Rows: "<resource> [<non-resource URLs>] [<resource names>] [<verbs>]"; non-resource rows have
    # no resource column. Verbs = the LAST bracket group (it may contain spaces).
    bad=$(printf '%s\n' "$perms" | awk '
      NR == 1 || NF == 0 { next }                                # header
      !match($0, /\[[^][]*\]$/) { print "unparseable: " $0; next }
      { verbs = substr($0, RSTART + 1, RLENGTH - 2); res = ($1 ~ /^\[/) ? "(non-resource) " $1 : $1 }
      # SelfSubject*Review creates are what can-i itself uses; they are not writes.
      res ~ /^selfsubject(access|rules)?reviews\.(authorization|authentication)\.k8s\.io$/ && verbs == "create" { next }
      { n = split(verbs, v, " "); for (i = 1; i <= n; i++) if (v[i] !~ /^(get|list|watch)$/) { print res " [" verbs "]"; next } }
      res ~ /^(\*|\*\.\*|secrets(\..*)?)$/ { print res " [" verbs "] (covers secrets)" }   # any read of secrets leaks them
    ')
    [ -z "$bad" ] || { echo "ABORT dev: $DEV_KUBE_SA is not read-only/secret-free; dev credential NOT installed:" >&2; printf '%s\n' "$bad" | sed 's/^/    /' >&2; ok=0; }
  fi
  if [ $ok = 1 ]; then
    if tok=$(k -n "$DEV_KUBE_NS" create token "$DEV_KUBE_SA" --duration=8h 2>"$ERR_DIR/dev-mint.err" | tr -d '[:space:]') \
       && is_jwt "$tok" && [ "$(jwt_sub "$tok")" = "$as" ]; then
      STACK_DEVKUBE_TOKEN="$tok"
      STACK_DEVKUBE_SERVER=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
      STACK_DEVKUBE_CA=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
      echo "→ dev: minted 8h READ-ONLY token for $DEV_KUBE_SA@$DEV_KUBE_NS (subject verified)"
    else
      echo "⚠ dev: mint failed or token failed the gate — continuing without dev kubectl" >&2; [ -s "$ERR_DIR/dev-mint.err" ] && sed 's/^/    /' "$ERR_DIR/dev-mint.err" >&2
    fi
  fi
else
  echo "→ dev: no DEV_KUBE_* in $ENV_FILE — kdev unavailable this session"
fi
export STACK_KUBE_TOKEN STACK_KUBE_SERVER STACK_KUBE_CA STACK_KUBE_NS="$KIND_NS" STACK_KUBE_SA="$KIND_SA"
export STACK_DEVKUBE_NS="${DEV_KUBE_NS:-}" STACK_DEVKUBE_SA="${DEV_KUBE_SA:-}"   # the dev token itself never enters the jail

[ -f "$SHARED_CREDS" ] || { echo "⚠ $SHARED_CREDS missing — log in once via \`jail-main\` first" >&2; exit 1; }

export STACK_NAME="$STACK" JAIL_NAME="$STACK" KIND_NET STACK_REPOS="$REPOS" UPLOAD_DIR="/workspace/$PRIMARY/uploads" UPLOAD_HOST_PORT="$UPLOAD_PORT"
export STACK_READS="${READ_PAIRS# }" JAIL_READS="$(echo ${READS:-} | tr ' ' '+')"
export GH_TOKEN GITLAB_HOST GITLAB_READ_TOKEN GITLAB_FORK_PATH GITLAB_DEPLOY_USER GITLAB_DEPLOY_TOKEN
VOLS=(
  -v "$STATE_DIR:/home/claude/.claude"
  -v "$SHARED_CREDS:/home/claude/.claude/.credentials.json"
  -v "$CLAUDE_JSON:/home/claude/.claude.json"
)
for r in $REPOS; do VOLS+=(-v "$JAIL_HOME/$STACK/$r:/workspace/$r"); done
# Git config + hooks read-only (repo and every submodule under .git/modules): both run on the HOST
# the next time host git or an IDE touches the repo (hooks, core.fsmonitor, core.sshCommand, filter
# drivers), and neither shows up in a diff. Costs: no repo-config writes in the jail (`push -u`,
# `remote add`, `branch --set-upstream-to`) — the global push.default/pushDefault cover pushing.
for r in $REPOS; do
  gd="$JAIL_HOME/$STACK/$r/.git"
  [ -d "$gd" ] || { [ -e "$gd" ] && echo "⚠ $r/.git is not a directory (worktree/submodule?) — config/hooks NOT protected" >&2; continue; }
  while IFS= read -r cfg; do
    d="${cfg%/config}"; rel="${d#"$JAIL_HOME/$STACK/"}"
    mkdir -p "$d/hooks"                                      # docker would create a missing source root-owned
    VOLS+=(-v "$cfg:/workspace/$rel/config:ro" -v "$d/hooks:/workspace/$rel/hooks:ro")
  done < <(find "$gd" -maxdepth 1 -name config -type f; [ -d "$gd/modules" ] && find "$gd/modules" -name config -type f -path '*/modules/*/config')
done
for pr in $READ_PAIRS; do VOLS+=(-v "$JAIL_HOME/${pr%%:*}/${pr#*:}:/reads/${pr%%:*}/${pr#*:}:ro"); done
PORTS=(-p "127.0.0.1:$UPLOAD_PORT:8000")                       # loopback only — office/client Wi-Fi
[ "$LOGIN" = 1 ] && PORTS+=(-p 127.0.0.1:54545:54545)

# ── the jail's network namespace: a pod, in Kubernetes terms ─────────────────────────────────────
# A pause container owns the namespace: the networks (a per-stack bridge for egress, plus the kind
# network) and the published ports. The jail joins it with network_mode container:<holder>, and so
# does the dev proxy. The proxy listens on 127.0.0.1 — a namespace's loopback is reachable only
# from processes inside that namespace, so nothing on the host, the LAN, other containers or kind
# pods can reach it, by construction. The dev token lives only in the proxy container (own PID and
# mount namespaces): the jail gets a credential-less kubeconfig, and the proxy refuses writes,
# secrets, exec/attach/portforward and service/pod proxying whoever the client is.
NETNS="jail-$STACK-net"; DEVPROXY="jail-$STACK-devproxy"; NET="jail-$STACK"
RUN_DIR="$JAIL_HOME/.run-$STACK"; mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"   # dev proxy audit logs
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
KUBECTL_IMAGE="${KUBECTL_IMAGE:-registry.k8s.io/kubectl:v1.37.1}"
SIDECAR=(--read-only --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)")

cleanup() {
  if docker container inspect "$DEVPROXY" >/dev/null 2>&1; then
    docker logs "$DEVPROXY" > "$RUN_DIR/devproxy-$(date +%Y%m%dT%H%M%S).log" 2>&1 || true
  fi
  docker rm -f "$DEVPROXY" "$NETNS" >/dev/null 2>&1 || true
  rm -f "$RUN_DIR/dev-kubeconfig"; rm -rf "$ERR_DIR"
}
trap cleanup EXIT
cleanup                                                           # leftovers of a crashed launch

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker run -d --rm --name "$NETNS" --network "$NET" "${PORTS[@]}" "${SIDECAR[@]}" "$PAUSE_IMAGE" >/dev/null
if [ -n "$STACK_KUBE_TOKEN" ]; then
  docker network connect "$KIND_NET" "$NETNS" || echo "⚠ could not join docker network '$KIND_NET' — kind unreachable" >&2
fi

STACK_DEVKUBE_PROXY=""
if [ -n "$STACK_DEVKUBE_TOKEN" ]; then
  # Read once at proxy start, deleted as soon as it is serving: the token is on the host disk for
  # seconds, mode 600, readable only by the host user (which the proxy runs as).
  ( umask 077; cat > "$RUN_DIR/dev-kubeconfig" <<EOT
apiVersion: v1
kind: Config
clusters: [{ name: dev, cluster: { server: "$STACK_DEVKUBE_SERVER", certificate-authority-data: "$STACK_DEVKUBE_CA" } }]
users:    [{ name: sa, user: { token: "$STACK_DEVKUBE_TOKEN" } }]
contexts: [{ name: dev, context: { cluster: dev, user: sa } }]
current-context: dev
EOT
  )
  # Filters (Go regexps, comma-separated, matched on the path segment so prefixes like // or
  # /api/v1/watch/ don't slip past). Methods: anything that is not exactly GET or HEAD — written
  # as the complement because Go regexps have no lookahead. A configmap or service literally named
  # "secrets"/"proxy"/"exec" is collateral; acceptable.
  docker run -d --name "$DEVPROXY" --network "container:$NETNS" "${SIDECAR[@]}" \
    --tmpfs /tmp -e HOME=/tmp -v "$RUN_DIR/dev-kubeconfig:/kubeconfig:ro" "$KUBECTL_IMAGE" \
    --kubeconfig=/kubeconfig proxy --address=127.0.0.1 --port=8001 -v=6 \
    --reject-methods='(?i)^([^gh].*|g([^e].*)?|ge([^t].*)?|get.+|h([^e].*)?|he([^a].*)?|hea([^d].*)?|head.+)$' \
    --reject-paths='(^|/)secrets(/|$),(^|/)(exec|attach|portforward|proxy)(/|$)' >/dev/null
  for _ in $(seq 1 50); do
    docker logs "$DEVPROXY" 2>&1 | grep -q 'Starting to serve' && break
    docker container inspect -f '{{.State.Running}}' "$DEVPROXY" 2>/dev/null | grep -q true || break
    sleep 0.2
  done
  rm -f "$RUN_DIR/dev-kubeconfig"
  if docker logs "$DEVPROXY" 2>&1 | grep -q 'Starting to serve'; then
    STACK_DEVKUBE_PROXY="http://127.0.0.1:8001"
    echo "→ dev: read-only proxy up in the jail's namespace (token stays in $DEVPROXY; audit log → $RUN_DIR/)"
  else
    echo "⚠ dev: proxy did not start — continuing without kdev. It said:" >&2
    docker logs "$DEVPROXY" 2>&1 | tail -5 | sed 's/^/    /' >&2
  fi
fi
unset STACK_DEVKUBE_TOKEN STACK_DEVKUBE_CA
export STACK_DEVKUBE_PROXY JAIL_NETNS="$NETNS"

# Not exec: the EXIT trap has to remove the holder + proxy (and save the proxy log) afterwards.
docker compose -f "$HERE/docker-compose.yml" run --rm \
  "${VOLS[@]}" \
  -e STACK_NAME -e JAIL_NAME -e JAIL_READS -e STACK_REPOS -e STACK_READS -e UPLOAD_DIR -e UPLOAD_HOST_PORT \
  -e GH_TOKEN -e GITLAB_HOST -e GITLAB_READ_TOKEN -e GITLAB_FORK_PATH -e GITLAB_DEPLOY_USER -e GITLAB_DEPLOY_TOKEN \
  -e STACK_KUBE_TOKEN -e STACK_KUBE_SERVER -e STACK_KUBE_CA -e STACK_KUBE_NS -e STACK_KUBE_SA \
  -e STACK_DEVKUBE_PROXY -e STACK_DEVKUBE_NS -e STACK_DEVKUBE_SA \
  stack \
  bash -c "source /workspace/tools/stack-jail-init.sh && cd /workspace/$PRIMARY && exec claude ${JAIL_CLAUDE_FLAGS:-}"
