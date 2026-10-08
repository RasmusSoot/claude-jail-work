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
#   - git: NO token in the jail. A gitproxy sidecar in the jail's network namespace holds the
#     fork-scoped GitHub token (resource owner = the trust-domain org, never the upstream), the
#     GitLab deploy token for a personal fork inside the client's GitLab and the read-only GitLab
#     token for fetching upstream; it forwards git smart-HTTP only, and accepts pushes only for the
#     stack's forks. The jail's git is routed to it with url.insteadOf (tools/stack-jail-init.sh).
#   - kubectl: TWO kubeconfig FILES, minted here per launch from the host credential, 8h:
#     kind.yaml = namespace-admin workbench SA on the local kind cluster (plain `kubectl`);
#     dev.yaml  = NO credential: points at a kubectl-proxy sidecar in the jail's network namespace
#     that holds the READ-ONLY SA token (minted only after impersonation proves it cannot mutate
#     or read secrets) and refuses writes, secrets and exec itself.
#   - filesystem: only $JAIL_HOME/<stack>/<repo> dirs and $JAIL_HOME/<stack>/notes are mounted, with
#     each repo's git internals read-only. No ~/.kube, no ~/.ssh, no Docker socket.
# Pushes are human (`! git push` or from the host) under the managed policy; the launcher never
# passes a permission-bypass flag. JAIL_CLAUDE_FLAGS exists for the day an exception is granted.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"           # this repo (the mechanism)
# shellcheck source=tools/host-tools.sh
. "$HERE/tools/host-tools.sh"                        # kubectl/kind/gh pinned by this repo's devbox.json
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"         # per-stack workspaces live here
STACK="${1:-}"; shift || true
LOGIN=0; [ "${1:-}" = "--login" ] && LOGIN=1
[ -n "$STACK" ] || { echo "usage: stack-jail.sh <stack> [--login]" >&2; exit 2; }

CONF="$HERE/stacks/$STACK.conf"
[ -f "$CONF" ] || { echo "FATAL: $CONF missing — add a stacks/<stack>.conf (see stacks/siva.conf)" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
: "${REPOS:?stacks/$STACK.conf must set REPOS}" "${PRIMARY:?must set PRIMARY}" "${UPLOAD_PORT:?must set UPLOAD_PORT}"
for r in $REPOS; do [ "$r" != notes ] || { echo "FATAL: stacks/$STACK.conf lists a repo named 'notes' — that name is the stack's notes dir" >&2; exit 2; }; done
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
  [ -d "$JAIL_HOME/$STACK/$r" ] || echo "⚠ $JAIL_HOME/$STACK/$r missing — run tools/stack-fork.sh $STACK first" >&2
done
[ -d "$JAIL_HOME/$STACK/$PRIMARY" ] || { echo "FATAL: the primary repo $PRIMARY is missing — run tools/stack-fork.sh $STACK" >&2; exit 2; }
# READ-ONLY views of other stacks: "<stack>:<repo>" pairs, resolved from each stack's own conf.
READ_PAIRS=""
for rs in ${READS:-}; do
  [ "$rs" != "$STACK" ] || continue
  [ -f "$HERE/stacks/$rs.conf" ] || { echo "⚠ READS: stacks/$rs.conf missing — skipping $rs" >&2; continue; }
  # shellcheck source=/dev/null
  for r in $(. "$HERE/stacks/$rs.conf" && echo "$REPOS"); do
    [ -d "$JAIL_HOME/$rs/$r" ] && READ_PAIRS="$READ_PAIRS $rs:$r" || echo "⚠ READS: $JAIL_HOME/$rs/$r missing — skipping" >&2
  done
done

"$HERE/tools/stack-env.sh" "$STACK" >/dev/null || exit 2          # creates the env template if missing
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

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
# shellcheck disable=SC2086  # TRUST_DIRS is a space-separated list: one argv entry per dir
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
# kind nodes are PRIVILEGED containers: a namespace admin who may run a privileged / hostPath /
# hostPID pod is root on the node and, through it, likely on the host. So before minting, the
# namespace must enforce Pod Security baseline or restricted (both forbid those pods), and the SA
# must not be able to take that away: no patch/update/delete of its namespace, no creating
# namespaces (a fresh one would have no label), no creating pods anywhere else. The label itself
# is set where the SA and RoleBinding are (the lab repo):
#   pod-security.kubernetes.io/enforce: baseline     # or restricted
kind_psa_gate() {
  local kk=(kubectl --context "kind-$KIND_CLUSTER") as="system:serviceaccount:$KIND_NS:$KIND_SA" psa bad=""
  psa=$("${kk[@]}" get ns "$KIND_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null) || psa=""
  case "$psa" in
    baseline|restricted) ;;
    *) echo "ABORT kind: namespace $KIND_NS has pod-security.kubernetes.io/enforce='${psa:-<unset>}' — needs baseline or restricted" >&2; return 1 ;;
  esac
  for v in patch update delete; do
    [ "$("${kk[@]}" auth can-i "$v" "namespace/$KIND_NS" --as="$as" 2>/dev/null)" = no ] || bad="$bad $v-namespace/$KIND_NS"
  done
  [ "$("${kk[@]}" auth can-i create namespaces --as="$as" 2>/dev/null)" = no ] || bad="$bad create-namespaces"
  [ "$("${kk[@]}" auth can-i create pods --all-namespaces --as="$as" 2>/dev/null)" = no ] || bad="$bad create-pods-cluster-wide"
  [ -z "$bad" ] || { echo "ABORT kind: $KIND_SA could undo the Pod Security label:$bad" >&2; return 1; }
  echo "→ kind: namespace $KIND_NS enforces Pod Security '$psa'; $KIND_SA cannot change it"
}

STACK_KUBE_TOKEN="" STACK_KUBE_SERVER="" STACK_KUBE_CA=""
if [ -z "$KIND_CLUSTER" ]; then
  echo "→ kind: none declared for $STACK — plain kubectl unavailable this session"
elif ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  echo "⚠ kind cluster '$KIND_CLUSTER' not found — continuing without kind kubectl" >&2
elif ! kind_psa_gate; then
  echo "⚠ kind: Pod Security gate failed — kind token NOT minted (see above)" >&2
else
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
      # DEV_KUBE_SERVER: the API as the proxy container reaches it, when that differs from the host
      # context's view (e.g. kind as a dev stand-in: https://<cluster>-control-plane:6443).
      STACK_DEVKUBE_SERVER=${DEV_KUBE_SERVER:-$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')}
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

export STACK_NAME="$STACK" JAIL_NAME="$STACK" KIND_NET STACK_REPOS="$REPOS" UPLOAD_DIR="/workspace/notes/uploads" UPLOAD_HOST_PORT="$UPLOAD_PORT"
# shellcheck disable=SC2086  # unquoted on purpose: echo squeezes the list's whitespace
JAIL_READS="$(echo ${READS:-} | tr ' ' '+')"
export STACK_READS="${READ_PAIRS# }" JAIL_READS
export GITLAB_HOST GITLAB_FORK_PATH FORK_ORG                     # facts for the card; the git tokens go to the sidecar only
VOLS=(
  -v "$STATE_DIR:/home/claude/.claude"
  -v "$SHARED_CREDS:/home/claude/.claude/.credentials.json"
  -v "$CLAUDE_JSON:/home/claude/.claude.json"
)
# Missing repos are skipped, not mounted: docker would create the source dir root-owned on the host.
for r in $REPOS; do [ -d "$JAIL_HOME/$STACK/$r" ] && VOLS+=(-v "$JAIL_HOME/$STACK/$r:/workspace/$r"); done
# Notes: a per-stack dir next to the repos, for things to share with agents and keep, but never
# commit or publish (client facts are fine — it never leaves this machine). A local git repo with
# no remote, so every session's changes are reviewable: the launcher commits a snapshot before and
# after each session (`git -C ~/claude/jail/<stack>/notes log -p`). uploads/ is the upload server's
# inbox — gitignored, and outside every client repo.
NOTES="$JAIL_HOME/$STACK/notes"
notes_git() { # hardened host-side git: explicit GIT_DIR/GIT_COMMON_DIR ignore a planted commondir,
              # -c overrides neutralise fsmonitor/hooks, no host or system config is read
  GIT_DIR="$NOTES/.git" GIT_COMMON_DIR="$NOTES/.git" GIT_WORK_TREE="$NOTES" \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
  git -c core.fsmonitor= -c core.hooksPath=/dev/null -c commit.gpgsign=false \
      -c user.name=stack-jail -c user.email=stack-jail@localhost "$@"
}
notes_snapshot() { # <message>
  [ -d "$NOTES/.git" ] || return 0
  notes_git add -A >/dev/null 2>&1 || return 0
  notes_git diff --cached --quiet 2>/dev/null || notes_git commit -q -m "$1" >/dev/null 2>&1 || true
}
if [ ! -d "$NOTES/.git" ]; then
  mkdir -p "$NOTES/uploads"
  printf '/uploads/\n' > "$NOTES/.gitignore"
  printf '# %s notes\n\nShared with every %s jail session, never committed to any repo or published.\n' "$STACK" "$STACK" > "$NOTES/README.md"
  notes_git init -q && notes_snapshot "notes: start"
  echo "→ notes: created $NOTES (local git, no remote)"
fi
mkdir -p "$NOTES/uploads"
notes_snapshot "before session $(date +%F\ %T)"
VOLS+=(-v "$NOTES:/workspace/notes")

# Git internals read-only (repo, every submodule under .git/modules, and notes): config, hooks and
# commondir all decide what HOST git runs the next time it — or an IDE sharing the working tree —
# touches the repo (hooks, core.fsmonitor, core.sshCommand, filter drivers), and none shows up in a
# diff. commondir is the subtle one: a gitdir may contain a file redirecting where config is read
# from. A normal clone has none; "." means "this gitdir", which is the same thing — so the launcher
# writes "." on the host and mounts it read-only, and the jail can neither create nor change it.
# Costs: no repo-config writes in the jail (`push -u`, `remote add`, `branch --set-upstream-to`).
GITDIRS=()
for r in $REPOS notes; do
  gd="$JAIL_HOME/$STACK/$r/.git"
  [ -d "$gd" ] || { [ -e "$gd" ] && echo "⚠ $r/.git is not a directory (worktree/submodule?) — git internals NOT protected" >&2; continue; }
  while IFS= read -r cfg; do
    d="${cfg%/config}"; rel="${d#"$JAIL_HOME/$STACK/"}"
    if [ -e "$d/commondir" ] && [ "$(cat "$d/commondir")" != "." ]; then
      echo "FATAL: $d/commondir points to '$(cat "$d/commondir")' — not a normal clone, or tampered with. Inspect it before launching." >&2; exit 2
    fi
    printf '.\n' > "$d/commondir"
    mkdir -p "$d/hooks"                                      # docker would create a missing source root-owned
    VOLS+=(-v "$cfg:/workspace/$rel/config:ro" -v "$d/hooks:/workspace/$rel/hooks:ro" -v "$d/commondir:/workspace/$rel/commondir:ro")
    GITDIRS+=("$d")
  done < <(find "$gd" -maxdepth 1 -name config -type f; [ -d "$gd/modules" ] && find "$gd/modules" -name config -type f -path '*/modules/*/config')
done

# What mounts cannot cover, checked on the host at start and exit: a nested repository planted in
# a working tree (IDEs auto-detect those and run git in them, with THEIR config), and the files git
# would only use for linked worktrees or per-worktree config. Warn loudly; deleting is the human's call.
own_submodule() { # <.git entry> <repo gitdir>: a .git FILE whose gitdir is inside <repo gitdir>/modules/
  local target real mods
  [ -f "$1" ] || return 1
  target=$(sed -n 's/^gitdir: //p' "$1"); [ -n "$target" ] || return 1
  real=$(cd "$(dirname "$1")" && cd "$target" 2>/dev/null && pwd -P) || return 1
  mods=$(cd "$2" && pwd -P)/modules/
  case "$real/" in "$mods"*) return 0;; *) return 1;; esac
}
audit_repos() { # <when>
  local r d hits=""
  for r in $REPOS notes; do
    [ -d "$JAIL_HOME/$STACK/$r/.git" ] || continue
    while IFS= read -r d; do
      own_submodule "$d" "$JAIL_HOME/$STACK/$r/.git" || hits="$hits\n    nested repo: $d"
    done < <(find "$JAIL_HOME/$STACK/$r" -mindepth 1 \( -path "$JAIL_HOME/$STACK/$r/.git" -prune \) -o \( -name .git -print -prune \) 2>/dev/null)
  done
  for d in ${GITDIRS[@]+"${GITDIRS[@]}"}; do                # bash 3.2 (macOS) + set -u: empty-array safe
    [ "$(cat "$d/commondir" 2>/dev/null)" = "." ] || hits="$hits\n    commondir changed: $d/commondir"
    [ ! -e "$d/config.worktree" ] || hits="$hits\n    per-worktree config: $d/config.worktree"
    [ ! -d "$d/worktrees" ] || hits="$hits\n    linked worktrees: $d/worktrees/ (yours?)"
  done
  [ -z "$hits" ] || printf '⚠ git audit (%s) — do NOT run git or open these in an IDE until inspected:%b\n' "$1" "$hits" >&2
}
audit_repos "before session"
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
# secrets, exec/attach/portforward and service/pod proxying whoever the client is. The git tokens
# live the same way in a gitproxy sidecar (127.0.0.1:8002): git smart-HTTP only, pushes only to
# this stack's forks, whoever the client is.
NETNS="jail-$STACK-net"; DEVPROXY="jail-$STACK-devproxy"; GITPROXY="jail-$STACK-gitproxy"; NET="jail-$STACK"
RUN_DIR="$JAIL_HOME/.run-$STACK"; mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"   # sidecar audit logs
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
KUBECTL_IMAGE="${KUBECTL_IMAGE:-registry.k8s.io/kubectl:v1.37.1}"
SIDECAR=(--read-only --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)")

cleanup() {
  local c
  for c in devproxy gitproxy; do
    if docker container inspect "jail-$STACK-$c" >/dev/null 2>&1; then
      docker logs "jail-$STACK-$c" > "$RUN_DIR/$c-$(date +%Y%m%dT%H%M%S).log" 2>&1 || true
    fi
  done
  docker rm -f "$DEVPROXY" "$GITPROXY" "$NETNS" >/dev/null 2>&1 || true
  rm -f "$RUN_DIR/dev-kubeconfig"
}
on_exit() { cleanup; audit_repos "after session"; notes_snapshot "after session $(date +%F\ %T)"; rm -rf "$ERR_DIR"; }
trap on_exit EXIT
cleanup                                                           # leftovers of a crashed launch (ERR_DIR stays: the sidecar + gh gates below still write there)

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker run -d --rm --name "$NETNS" --network "$NET" "${PORTS[@]}" "${SIDECAR[@]}" "$PAUSE_IMAGE" >/dev/null
if [ -n "$KIND_CLUSTER" ] && docker network inspect "$KIND_NET" >/dev/null 2>&1; then   # reach, not access
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

# ── git: the tokens go to the gitproxy sidecar, never to the jail ───────────────────────────────
# Write allowlist = this stack's forks only: FORK_ORG/<repo> for each REPOS entry on GitHub, and the
# GitLab fork path. Read allowlist = where the GitHub token is sent at all: those forks plus
# UPSTREAM_OWNER/<repo>; every other github.com repo is fetched anonymously. The token reaches every
# repo in the fork org (other stacks' forks too, private ones included); the two lists narrow it to
# this stack's. Anything else the sidecar refuses before the token is used.
STACK_GITPROXY="" GITPROXY_WRITE="" GITPROXY_READ=""
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITLAB_HOST:-}" ]; then
  if [ -n "${GH_TOKEN:-}" ] && [ -n "${FORK_ORG:-}" ]; then
    for r in $REPOS; do
      GITPROXY_WRITE="$GITPROXY_WRITE,github.com/$FORK_ORG/$r"
      [ -z "${UPSTREAM_OWNER:-}" ] || GITPROXY_READ="$GITPROXY_READ,github.com/$UPSTREAM_OWNER/$r"
    done
  fi
  [ -n "${GITLAB_HOST:-}" ] && [ -n "${GITLAB_FORK_PATH:-}" ] && GITPROXY_WRITE="$GITPROXY_WRITE,$GITLAB_HOST/$GITLAB_FORK_PATH"
  GITPROXY_WRITE="${GITPROXY_WRITE#,}"; GITPROXY_READ="${GITPROXY_READ#,}"
  export GITPROXY_WRITE GITPROXY_READ GITPROXY_LISTEN="127.0.0.1:8002" GH_TOKEN GITLAB_HOST GITLAB_READ_TOKEN GITLAB_FORK_PATH GITLAB_DEPLOY_USER GITLAB_DEPLOY_TOKEN
  docker compose -f "$HERE/docker-compose.yml" run -d --name "$GITPROXY" \
    -e GITPROXY_LISTEN -e GITPROXY_WRITE -e GITPROXY_READ -e GH_TOKEN -e GITLAB_HOST -e GITLAB_READ_TOKEN \
    -e GITLAB_FORK_PATH -e GITLAB_DEPLOY_USER -e GITLAB_DEPLOY_TOKEN gitproxy >/dev/null 2>"$ERR_DIR/gitproxy.err" || true
  for _ in $(seq 1 50); do
    docker logs "$GITPROXY" 2>&1 | grep -q 'gitproxy: serving' && break
    docker container inspect -f '{{.State.Running}}' "$GITPROXY" 2>/dev/null | grep -q true || break
    sleep 0.2
  done
  if docker logs "$GITPROXY" 2>&1 | grep -q 'gitproxy: serving'; then
    STACK_GITPROXY="http://$GITPROXY_LISTEN"
    echo "→ git: credential sidecar up in the jail's namespace (tokens stay in $GITPROXY; GitHub token only for: ${GITPROXY_READ:-<none>} + forks; pushes only to: ${GITPROXY_WRITE:-<none>}; audit log → $RUN_DIR/)"
  else
    echo "⚠ git: sidecar did not start — the session has NO git credential (public fetches only). It said:" >&2
    { cat "$ERR_DIR/gitproxy.err"; docker logs "$GITPROXY" 2>&1; } | tail -5 | sed 's/^/    /' >&2
  fi
else
  echo "→ git: no GH_TOKEN and no GITLAB_HOST in $ENV_FILE — no git credential this session"
fi
unset GH_TOKEN GITLAB_READ_TOKEN GITLAB_DEPLOY_USER GITLAB_DEPLOY_TOKEN
export STACK_GITPROXY GITPROXY_WRITE

# ── gh: the one token that may enter the jail, because its leak must be harmless ─────────────────
# A fine-grained PAT with "Public repositories" access and no permissions grants nothing anyone
# lacks, only the authenticated rate limit for gh reads. Gate before injecting: fine-grained shape
# (classic tokens cannot be verified this way), valid, and it sees NO private repository. The
# permission set itself cannot be probed without writing; that part is the human's.
GH_TOKEN=""                                                      # what the JAIL gets as GH_TOKEN: gh's, or nothing
if [ -n "${GH_PUBLIC_TOKEN:-}" ]; then
  # The token goes to curl through a config file (mode 600 in ERR_DIR), never on the host's argv.
  ( umask 077; printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\n' "$GH_PUBLIC_TOKEN" > "$ERR_DIR/gh-curl.cfg" )
  gh_api() { curl -sS --max-time 15 -K "$ERR_DIR/gh-curl.cfg" "https://api.github.com/$1" 2>>"$ERR_DIR/gh-public.err"; }
  case "$GH_PUBLIC_TOKEN" in github_pat_*) ;; *) echo "ABORT gh: GH_PUBLIC_TOKEN is not a fine-grained token (github_pat_…) — NOT installed" >&2; GH_PUBLIC_TOKEN=unverifiable ;; esac
  if [ "$GH_PUBLIC_TOKEN" != unverifiable ]; then
    # Any failure (network, non-JSON) leaves the variables empty / "?" and refuses: fail closed, not out.
    login=$(gh_api user | jq -r '.login // empty' 2>/dev/null) || login=""
    private=$(gh_api 'user/repos?visibility=private&per_page=1' | jq -r 'if type == "array" then length else "?" end' 2>/dev/null) || private="?"
    if [ -z "$login" ]; then
      echo "ABORT gh: GH_PUBLIC_TOKEN is not valid or api.github.com is unreachable (GET /user failed) — NOT installed" >&2; sed 's/^/    /' "$ERR_DIR/gh-public.err" >&2
    elif [ "$private" != 0 ]; then
      echo "ABORT gh: GH_PUBLIC_TOKEN can see private repositories (or the probe failed: '$private') — NOT installed" >&2
    else
      GH_TOKEN="$GH_PUBLIC_TOKEN"
      echo "→ gh: public-read-only token for $login enters the jail (authenticated rate limit; writes are refused by GitHub)"
    fi
  fi
  rm -f "$ERR_DIR/gh-curl.cfg"
else
  echo "→ gh: no GH_PUBLIC_TOKEN in $ENV_FILE — gh is unauthenticated in the jail (anonymous rate limit)"
fi
unset GH_PUBLIC_TOKEN
export GH_TOKEN

# Not exec: the EXIT trap has to remove the holder + sidecars (and save their logs) afterwards.
docker compose -f "$HERE/docker-compose.yml" run --rm \
  "${VOLS[@]}" \
  -e STACK_NAME -e JAIL_NAME -e JAIL_READS -e STACK_REPOS -e STACK_READS -e UPLOAD_DIR -e UPLOAD_HOST_PORT \
  -e STACK_GITPROXY -e GITPROXY_WRITE -e GITLAB_HOST -e GITLAB_FORK_PATH -e FORK_ORG -e GH_TOKEN \
  -e STACK_KUBE_TOKEN -e STACK_KUBE_SERVER -e STACK_KUBE_CA -e STACK_KUBE_NS -e STACK_KUBE_SA \
  -e STACK_DEVKUBE_PROXY -e STACK_DEVKUBE_NS -e STACK_DEVKUBE_SA \
  stack \
  bash -c "source /workspace/tools/stack-jail-init.sh && cd /workspace/$PRIMARY && exec claude ${JAIL_CLAUDE_FLAGS:-}"
