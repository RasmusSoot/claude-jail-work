#!/usr/bin/env bash
# client-jail — host-side launcher for a per-client jail (the credential airlock).
#
#   client-jail.sh <client> [--login]
#
# One jail per client. What a client IS comes from two files:
#   clients/<client>.conf          committed, generic: repos, primary dir, kind cluster, upload port
#   $JAIL_HOME/.env.<client>       gitignored: tokens + client FACTS (dev context, CIDR, GitLab host)
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
#   - filesystem: only $JAIL_HOME/<client>/<repo> dirs are mounted. No ~/.kube, no ~/.ssh,
#     no Docker socket.
# Pushes are human (`! git push` or from the host) under the managed policy; the launcher never
# passes a permission-bypass flag. JAIL_CLAUDE_FLAGS exists for the day an exception is granted.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"           # this repo (the mechanism)
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"         # per-client workspaces live here
CLIENT="${1:-}"; shift || true
LOGIN=0; [ "${1:-}" = "--login" ] && LOGIN=1
[ -n "$CLIENT" ] || { echo "usage: client-jail.sh <client> [--login]" >&2; exit 2; }

CONF="$HERE/clients/$CLIENT.conf"
[ -f "$CONF" ] || { echo "FATAL: $CONF missing — add a clients/<client>.conf (see clients/siva.conf)" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
: "${REPOS:?clients/$CLIENT.conf must set REPOS}" "${PRIMARY:?must set PRIMARY}" "${UPLOAD_PORT:?must set UPLOAD_PORT}"
KIND_CLUSTER="${KIND_CLUSTER:-$CLIENT}"
KIND_NET="${KIND_NET:-kind}"                        # docker network the kind nodes sit on
KIND_NS="${KIND_NS:-$CLIENT}"
KIND_SA="${KIND_SA:-$CLIENT-workbench}"

ENV_FILE="$JAIL_HOME/.env.$CLIENT"
STATE_DIR="$JAIL_HOME/.claude-data-$CLIENT"
CLAUDE_JSON="$JAIL_HOME/.claude-data-$CLIENT.json"
SHARED_CREDS="$JAIL_HOME/.claude-data/.credentials.json"   # login once via `jail-main`

mkdir -p "$STATE_DIR" "$JAIL_HOME/$CLIENT"
[ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
touch "$JAIL_HOME/.claude-data-$CLIENT.zsh_history"
for r in $REPOS; do
  [ -d "$JAIL_HOME/$CLIENT/$r" ] || echo "⚠ $JAIL_HOME/$CLIENT/$r missing — clone it first (upstream fetch-only, origin = your fork)" >&2
done

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOT
# $CLIENT jail — tokens + client FACTS. Gitignored; never copy values into any repo.
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

# Bootstrap the per-client Claude config from the login jail's solved state (onboarding, theme,
# statusline) — once; per-client overrides then stick.
if [ ! -f "$STATE_DIR/settings.json" ] && [ -f "$JAIL_HOME/.claude-data/settings.json" ]; then
  python3 - "$JAIL_HOME/.claude-data/settings.json" "$STATE_DIR/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
if "statusLine" in s: s["statusLine"]["command"] = "/home/node/.claude/statusline.sh"
json.dump(s, open(sys.argv[2], "w"), indent=2)
PY
  cp "$HERE/.claude/statusline.sh" "$STATE_DIR/statusline.sh"; chmod +x "$STATE_DIR/statusline.sh"
fi
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

# ── token gates shared by both mints ────────────────────────────────────────────────────────────
is_jwt()  { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; }
jwt_sub() { # decode the JWT payload locally (base64url + padding) and print .sub; never prints the token
  local p; p=$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  printf '%s' "$p" | base64 -d 2>/dev/null | jq -r '.sub // empty'
}

# ── kind: namespace-admin workbench SA, 8h, server = in-network control-plane name ──────────────
STACK_KUBE_TOKEN="" STACK_KUBE_SERVER="" STACK_KUBE_CA=""
if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  if tok=$(kubectl --context "kind-$KIND_CLUSTER" -n "$KIND_NS" create token "$KIND_SA" --duration=8h 2>/tmp/kind-mint.err | tr -d '[:space:]'); then
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
    sed 's/^/    /' /tmp/kind-mint.err >&2
  fi
else
  echo "⚠ kind cluster '$KIND_CLUSTER' not found — continuing without kind kubectl" >&2
fi

# ── client dev: READ-ONLY SA, proven by impersonation BEFORE minting, 8h ────────────────────────
STACK_DEVKUBE_TOKEN="" STACK_DEVKUBE_SERVER="" STACK_DEVKUBE_CA=""
if [ -n "${DEV_KUBE_CONTEXT:-}" ] && [ -n "${DEV_KUBE_NS:-}" ] && [ -n "${DEV_KUBE_SA:-}" ]; then
  k() { kubectl --context "$DEV_KUBE_CONTEXT" "$@"; }
  as="system:serviceaccount:$DEV_KUBE_NS:$DEV_KUBE_SA"; ok=1
  for v in create delete patch update; do
    [ "$(k auth can-i "$v" pods -n "$DEV_KUBE_NS" --as="$as" 2>/dev/null)" = "no" ] || { echo "ABORT dev: $DEV_KUBE_SA can $v pods — not read-only; dev credential NOT installed" >&2; ok=0; break; }
  done
  [ $ok = 1 ] && { [ "$(k auth can-i get secrets -n "$DEV_KUBE_NS" --as="$as" 2>/dev/null)" = "no" ] || { echo "ABORT dev: $DEV_KUBE_SA can read secrets; dev credential NOT installed" >&2; ok=0; }; }
  if [ $ok = 1 ]; then
    if tok=$(k -n "$DEV_KUBE_NS" create token "$DEV_KUBE_SA" --duration=8h 2>/tmp/dev-mint.err | tr -d '[:space:]') \
       && is_jwt "$tok" && [ "$(jwt_sub "$tok")" = "$as" ]; then
      STACK_DEVKUBE_TOKEN="$tok"
      STACK_DEVKUBE_SERVER=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
      STACK_DEVKUBE_CA=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
      echo "→ dev: minted 8h READ-ONLY token for $DEV_KUBE_SA@$DEV_KUBE_NS (subject verified)"
    else
      echo "⚠ dev: mint failed or token failed the gate — continuing without dev kubectl" >&2; [ -s /tmp/dev-mint.err ] && sed 's/^/    /' /tmp/dev-mint.err >&2
    fi
  fi
else
  echo "→ dev: no DEV_KUBE_* in $ENV_FILE — kdev unavailable this session"
fi
export STACK_KUBE_TOKEN STACK_KUBE_SERVER STACK_KUBE_CA STACK_KUBE_NS="$KIND_NS" STACK_KUBE_SA="$KIND_SA"
export STACK_DEVKUBE_TOKEN STACK_DEVKUBE_SERVER STACK_DEVKUBE_CA STACK_DEVKUBE_NS="${DEV_KUBE_NS:-}" STACK_DEVKUBE_SA="${DEV_KUBE_SA:-}"

[ -f "$SHARED_CREDS" ] || { echo "⚠ $SHARED_CREDS missing — log in once via \`jail-main\` first" >&2; exit 1; }

export CLIENT_NAME="$CLIENT" JAIL_NAME="$CLIENT" KIND_NET CLIENT_REPOS="$REPOS" UPLOAD_DIR="/workspace/$PRIMARY/uploads"
export GH_TOKEN GITLAB_HOST GITLAB_READ_TOKEN GITLAB_FORK_PATH GITLAB_DEPLOY_USER GITLAB_DEPLOY_TOKEN
VOLS=(
  -v "$STATE_DIR:/home/node/.claude"
  -v "$SHARED_CREDS:/home/node/.claude/.credentials.json"
  -v "$CLAUDE_JSON:/home/node/.claude.json"
  -v "$JAIL_HOME/.claude-data-$CLIENT.zsh_history:/home/node/.zsh_history"
)
for r in $REPOS; do VOLS+=(-v "$JAIL_HOME/$CLIENT/$r:/workspace/$r"); done
PORTS=(-p "127.0.0.1:$UPLOAD_PORT:8000")                       # loopback only — office/client Wi-Fi
[ "$LOGIN" = 1 ] && PORTS+=(-p 127.0.0.1:54545:54545)

exec docker compose -f "$HERE/docker-compose.yml" run --rm \
  "${PORTS[@]}" "${VOLS[@]}" \
  -e CLIENT_NAME -e JAIL_NAME -e CLIENT_REPOS -e UPLOAD_DIR \
  -e GH_TOKEN -e GITLAB_HOST -e GITLAB_READ_TOKEN -e GITLAB_FORK_PATH -e GITLAB_DEPLOY_USER -e GITLAB_DEPLOY_TOKEN \
  -e STACK_KUBE_TOKEN -e STACK_KUBE_SERVER -e STACK_KUBE_CA -e STACK_KUBE_NS -e STACK_KUBE_SA \
  -e STACK_DEVKUBE_TOKEN -e STACK_DEVKUBE_SERVER -e STACK_DEVKUBE_CA -e STACK_DEVKUBE_NS -e STACK_DEVKUBE_SA \
  client \
  zsh -c "source /workspace/tools/client-jail-init.sh && cd /workspace/$PRIMARY && exec claude ${JAIL_CLAUDE_FLAGS:-}"
