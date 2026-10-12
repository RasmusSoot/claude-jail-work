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
#   - filesystem: only $JAIL_HOME/<stack>/<repo> dirs, $JAIL_HOME/<stack>/notes and (with a builder)
#     $JAIL_HOME/<stack>/build are mounted, with each repo's git internals read-only. No ~/.kube,
#     no ~/.ssh, no Docker socket.
#   - images: no docker in the jail. BUILDER_IMAGE in the conf starts a build sidecar (the Paketo
#     builder + helm, tools/builder/) that runs the CNB lifecycle on requests from the build dir
#     and pushes image + chart to the kind registry, names from BUILD_NAMES only, with the
#     registry credential (if any) held by the sidecar. Jail side: tools/build-image.
# Pushes are human (`! git push` or from the host) under the managed policy; the launcher never
# passes a permission-bypass flag. JAIL_CLAUDE_FLAGS exists for the day an exception is granted.
set -euo pipefail

# The whole launcher is one function, called at the very end: bash then parses the entire file
# before running any of it. Otherwise it reads the script incrementally from its open descriptor,
# and this script blocks for a whole session on `docker compose run` while jail-main may be
# editing the file — on return, bash resumes at a byte offset in a file that changed under it
# ("unexpected EOF while looking for matching …" at exit, EXIT trap at risk).
main() {

HERE="$(cd "$(dirname "$0")/.." && pwd)"           # this repo (the mechanism)
# shellcheck source=tools/host-tools.sh
. "$HERE/tools/host-tools.sh"                        # kubectl/kind/gh pinned by this repo's devbox.json
JAIL_HOME="${JAIL_HOME:-$HOME/claude/jail}"         # per-stack workspaces live here
STACK="${1:-}"; shift || true
LOGIN=0; [ "${1:-}" = "--login" ] && LOGIN=1
[ -n "$STACK" ] || { echo "usage: stack-jail.sh <stack> [--login]" >&2; exit 2; }

CONF="$HERE/stacks/$STACK.conf"
[ -f "$CONF" ] || { fail "FATAL: $CONF missing — add a stacks/<stack>.conf (see stacks/siva.conf)"; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
: "${REPOS:?stacks/$STACK.conf must set REPOS}" "${PRIMARY:?must set PRIMARY}" "${UPLOAD_PORT:?must set UPLOAD_PORT}"
for r in $REPOS; do case "$r" in notes|build) fail "FATAL: stacks/$STACK.conf lists a repo named '$r' — that name is the stack's $r dir"; exit 2;; esac; done
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
  [ -d "$JAIL_HOME/$STACK/$r" ] || warn "$JAIL_HOME/$STACK/$r missing — run tools/stack-fork.sh $STACK first"
done
[ -d "$JAIL_HOME/$STACK/$PRIMARY" ] || { fail "FATAL: the primary dir $PRIMARY is missing — run tools/stack-fork.sh $STACK (or mkdir it, if it is a local-only dir)"; exit 2; }
# READ-ONLY views of other stacks: "<stack>:<repo>" pairs, resolved from each stack's own conf.
READ_PAIRS=""
for rs in ${READS:-}; do
  [ "$rs" != "$STACK" ] || continue
  [ -f "$HERE/stacks/$rs.conf" ] || { warn "READS: stacks/$rs.conf missing — skipping $rs"; continue; }
  # shellcheck source=/dev/null
  for r in $(. "$HERE/stacks/$rs.conf" && echo "$REPOS"); do
    if [ -d "$JAIL_HOME/$rs/$r" ]; then READ_PAIRS="$READ_PAIRS $rs:$r"; else warn "READS: $JAIL_HOME/$rs/$r missing — skipping"; fi
  done
done

"$HERE/tools/stack-env.sh" "$STACK" >/dev/null || exit 2          # creates the env template if missing
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

# Bootstrap the per-stack Claude config from the login jail's solved state (onboarding, theme)
# — once; per-stack overrides then stick. Pinned on EVERY launch: statusLine (it lives in this
# repo's project settings, which a stack jail never sees; the script is tools/, mounted ro) and
# permissions.allow. The allow list skips the permission prompt / auto-mode classifier for what it
# matches: inside a stack jail the prompts are scenery (tokens + git are the boundaries), so the
# default allows everything per tool. A managed deny still wins, and a managed policy may ignore
# non-managed rules altogether; a managed ask rule (e.g. Bash(curl *)) prompts despite Bash(*). stacks/<stack>.conf may set JAIL_ALLOW (comma-separated rules,
# since rules contain spaces; "" = none). This is the jail's own ~/.claude/settings.json, which the
# jail could edit anyway.
JAIL_ALLOW="${JAIL_ALLOW-Bash(*), Edit(*), Write(*), Read(*), NotebookEdit(*), WebFetch(domain:*), WebSearch}"
JAIL_ALLOW="$JAIL_ALLOW" python3 - "$JAIL_HOME/.claude-data/settings.json" "$STATE_DIR/settings.json" <<'PY'
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
allow = [r.strip() for r in os.environ.get("JAIL_ALLOW", "").split(",") if r.strip()]
if os.path.exists(dst): s = json.load(open(dst))
elif os.path.exists(src): s = json.load(open(src))
else: s = {}
s["statusLine"] = {"type": "command", "command": "/workspace/tools/statusline.sh", "padding": 1}
s.setdefault("permissions", {})["allow"] = allow
json.dump(s, open(dst, "w"), indent=2)
PY
ok "permissions: allow = ${JAIL_ALLOW:-<none>} (per-stack settings; managed deny and ask rules still win)"
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

# shellcheck disable=SC2329  # invoked by the trap string; redefined once a token exists
argo_revoke() { :; }
ERR_DIR=$(mktemp -d); trap 'argo_revoke; rm -rf "$ERR_DIR"' EXIT   # mint stderr; no fixed /tmp names (cleanup() takes over later)
# ── token gates shared by both mints ────────────────────────────────────────────────────────────
is_jwt()  { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; }
gitdir_id() { # <gitdir> → inode of the dir, inode + checksum of its config: "replaced" shows up as a change (ls -di and cksum: POSIX, macOS too)
  # shellcheck disable=SC2012  # only the inode column is used, so an odd filename cannot mislead
  printf '%s %s %s' "$(ls -di "$1" | awk '{print $1}')" "$(ls -di "$1/config" 2>/dev/null | awk '{print $1}')" "$(cksum < "$1/config" 2>/dev/null | awk '{print $1}')"
}
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
# namespaces (a fresh one would have no label), no creating pods anywhere else. The label, the SA
# and its RoleBinding are applied by tools/kind-stack.sh <stack> up (host-side, from the conf):
#   pod-security.kubernetes.io/enforce: baseline     # or restricted
kind_psa_gate() {
  local kk=(kubectl --context "kind-$KIND_CLUSTER") as="system:serviceaccount:$KIND_NS:$KIND_SA" psa bad=""
  # A failed read is not "label unset": the API may be down or the namespace missing. Say which.
  if ! psa=$("${kk[@]}" get ns "$KIND_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>"$ERR_DIR/kind-ns.err"); then
    fail "ABORT kind: cannot read namespace $KIND_NS on kind-$KIND_CLUSTER (cluster down? namespace missing?). kubectl said:"
    sed 's/^/    /' "$ERR_DIR/kind-ns.err" | head -3 >&2; return 1
  fi
  case "$psa" in
    baseline|restricted) ;;
    *) fail "ABORT kind: namespace $KIND_NS has pod-security.kubernetes.io/enforce='${psa:-<unset>}' — needs baseline or restricted"; return 1 ;;
  esac
  # A request on namespaces/<ns> is evaluated WITH namespace=<ns>, so RoleBindings inside that
  # namespace count: ask with -n, or a binding there (one a pushed chart made Argo create, say)
  # is never consulted and the gate passes a SA that can drop the label.
  for v in patch update delete; do
    [ "$("${kk[@]}" auth can-i "$v" "namespace/$KIND_NS" -n "$KIND_NS" --as="$as" 2>/dev/null)" = no ] || bad="$bad $v-namespace/$KIND_NS"
  done
  [ "$("${kk[@]}" auth can-i create namespaces --as="$as" 2>/dev/null)" = no ] || bad="$bad create-namespaces"
  # Pods in any namespace without a Pod Security label, one namespace at a time: --all-namespaces
  # answers "no" as soon as a single namespace is out of reach, which hides a grant in `default`.
  local ns lbl
  while IFS=$'\t' read -r ns lbl; do
    case "$lbl" in baseline|restricted) continue ;; esac
    [ "$("${kk[@]}" auth can-i create pods -n "$ns" --as="$as" 2>/dev/null)" = no ] || bad="$bad create-pods-in-$ns"
  done < <("${kk[@]}" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}' 2>/dev/null)
  [ -z "$bad" ] || { fail "ABORT kind: $KIND_SA could undo the Pod Security label:$bad"; return 1; }
  ok "kind: namespace $KIND_NS enforces Pod Security '$psa'; $KIND_SA cannot change it"
}

STACK_KUBE_TOKEN="" STACK_KUBE_SERVER="" STACK_KUBE_CA=""
if [ -z "$KIND_CLUSTER" ]; then
  info "kind: none declared for $STACK — plain kubectl unavailable this session"
elif ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  warn "kind cluster '$KIND_CLUSTER' not found (tools/kind-stack.sh $STACK up) — continuing without kind kubectl"
elif [ "$(docker container inspect -f '{{.State.Running}}' "$KIND_CLUSTER-control-plane" 2>/dev/null)" != true ]; then
  # `kind get clusters` lists stopped clusters too; a stopped node fails every later check.
  warn "kind cluster '$KIND_CLUSTER' exists but is not running (tools/kind-stack.sh $STACK up) — continuing without kind kubectl"
elif ! kind_psa_gate; then
  warn "kind: Pod Security gate failed — kind token NOT minted (see above; tools/kind-stack.sh $STACK up applies the namespace, label and SA)"
else
  if tok=$(kubectl --context "kind-$KIND_CLUSTER" -n "$KIND_NS" create token "$KIND_SA" --duration=8h 2>"$ERR_DIR/kind-mint.err" | tr -d '[:space:]'); then
    if is_jwt "$tok" && [ "$(jwt_sub "$tok")" = "system:serviceaccount:$KIND_NS:$KIND_SA" ]; then
      STACK_KUBE_TOKEN="$tok"
      _ikc=$(mktemp); kind get kubeconfig --internal --name "$KIND_CLUSTER" > "$_ikc"
      STACK_KUBE_SERVER=$(kubectl --kubeconfig "$_ikc" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
      STACK_KUBE_CA=$(kubectl --kubeconfig "$_ikc" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
      rm -f "$_ikc"
      ok "kind: minted 8h token for $KIND_SA@$KIND_NS ($STACK_KUBE_SERVER)"
    else
      warn "kind: minted token failed the shape/subject gate — continuing without kind kubectl"
    fi
  else
    warn "kind: could not mint token for $KIND_SA@$KIND_NS (create the SA + RoleBinding in the lab repo). kubectl said:"
    sed 's/^/    /' "$ERR_DIR/kind-mint.err" >&2
  fi
fi

# ── argocd: an 8h get+sync token for the stack's own Argo account, gated like the kind token ─────
# tools/kind-stack.sh creates the account (<stack>-jail, apiKey only) and its whole policy: get,
# sync and logs on the stack's project. The launcher logs in as admin over the API server's NodePort
# on the kind network (that admin password is the disposable kind cluster's), mints a token with an
# id of its own, checks shape and subject, then asks the API *as that token* what it may do: every
# write it must not have (app create/update/delete/override, account update = minting more tokens,
# repository create, project update) has to answer "no" and sync "yes". Deleted again at session end.
STACK_ARGO_SERVER="" STACK_ARGO_TOKEN="" ARGO_TOKEN_ID="" ARGO_URL=""
ARGO_ACCOUNT="$STACK-jail"; ARGO_NODEPORT="${ARGO_NODEPORT:-30443}"
argo_api() { curl -sSk --max-time 15 -K "$ERR_DIR/argo-$1.cfg" -H 'Content-Type: application/json' "${@:2}" 2>>"$ERR_DIR/argo.err"; }
argo_revoke() {
  [ -n "${ARGO_TOKEN_ID:-}" ] && [ -f "${ERR_DIR:-/nonexistent}/argo-admin.cfg" ] || return 0
  if argo_api admin -X DELETE "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT/token/$ARGO_TOKEN_ID" >/dev/null; then
    ok "argocd: token $ARGO_TOKEN_ID deleted"
  else
    warn "argocd: could not delete token $ARGO_TOKEN_ID (it expires on its own)"
  fi
  ARGO_TOKEN_ID=""
}
if [ -z "${ARGO_APPS:-}" ]; then
  info "argocd: no ARGO_APPS in stacks/$STACK.conf — argocd unavailable this session"
elif [ -z "$STACK_KUBE_TOKEN" ]; then
  warn "argocd: skipped — no kind token this session"
else
  node_ip=$(docker container inspect -f "{{with index .NetworkSettings.Networks \"$KIND_NET\"}}{{.IPAddress}}{{end}}" "$KIND_CLUSTER-control-plane" 2>/dev/null) || node_ip=""
  admin_pw=$(kubectl --context "kind-$KIND_CLUSTER" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>"$ERR_DIR/argo.err" | base64 -d) || admin_pw=""
  if [ -z "$node_ip" ] || [ -z "$admin_pw" ]; then
    warn "argocd: not installed on kind-$KIND_CLUSTER, or the control-plane has no address on '$KIND_NET' (tools/kind-stack.sh $STACK up) — continuing without argocd"
  else
    ARGO_URL="https://$node_ip:$ARGO_NODEPORT"
    ( umask 077; : > "$ERR_DIR/argo-none.cfg" )                 # the password travels on stdin, never argv
    sess=$(jq -n --arg p "$admin_pw" '{username:"admin",password:$p}' | argo_api none -X POST "$ARGO_URL/api/v1/session" -d @- | jq -r '.token // empty' 2>/dev/null) || sess=""
    unset admin_pw
    if [ -z "$sess" ]; then
      warn "argocd: admin login at $ARGO_URL failed — continuing without argocd. It said:"; tail -3 "$ERR_DIR/argo.err" | sed 's/^/    /' >&2
    else
      ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$sess" > "$ERR_DIR/argo-admin.cfg" ); unset sess
      # Tokens of earlier launches that expired without a delete (a crash skips argo_revoke) go first.
      for old in $(argo_api admin "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT" \
                   | jq -r --argjson now "$(date +%s)" '.tokens[]? | ((.expiresAt // 0) | tonumber) as $e | select($e > 0 and $e < $now) | .id' 2>/dev/null); do
        argo_api admin -X DELETE "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT/token/$old" >/dev/null || true
      done
      ARGO_TOKEN_ID="jail-$(date +%Y%m%dT%H%M%S)"
      tok=$(jq -n --arg id "$ARGO_TOKEN_ID" '{expiresIn: 28800, id: $id}' \
            | argo_api admin -X POST "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT/token" -d @- | jq -r '.token // empty' 2>/dev/null) || tok=""
      if [ -z "$tok" ]; then
        warn "argocd: could not mint a token for account $ARGO_ACCOUNT (tools/kind-stack.sh $STACK up creates it) — continuing without argocd. It said:"
        tail -3 "$ERR_DIR/argo.err" | sed 's/^/    /' >&2; ARGO_TOKEN_ID=""
      elif ! is_jwt "$tok" || [ "$(jwt_sub "$tok")" != "$ARGO_ACCOUNT:apiKey" ]; then
        warn "argocd: minted token failed the shape/subject gate (sub='$(jwt_sub "$tok" 2>/dev/null)') — deleted, continuing without argocd"; argo_revoke
      else
        ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" > "$ERR_DIR/argo-jail.cfg" )
        can_i() { argo_api jail "$ARGO_URL/api/v1/account/can-i/$1" | jq -r '.value // "?"' 2>/dev/null || echo "?"; }
        bad=""
        # The policy is glob-matched against the request object, so a grant on one app name
        # answers "no" to the wildcard probe: probe each name too, and the untouched default project.
        probes=("applications/create/$STACK/*" "applications/update/$STACK/*" "applications/delete/$STACK/*" "applications/override/$STACK/*" \
                "applications/update/default/*" "applications/create/default/*" "accounts/update/$ARGO_ACCOUNT" "repositories/create/*" "projects/update/$STACK")
        for _app in $ARGO_APPS; do probes+=("applications/update/$STACK/$_app" "applications/delete/$STACK/$_app" "applications/override/$STACK/$_app"); done
        for q in "${probes[@]}"; do
          [ "$(can_i "$q")" = no ] || bad="$bad $q"
        done
        [ "$(can_i "applications/sync/$STACK/*")" = yes ] || bad="$bad no-sync"
        for _app in $ARGO_APPS; do [ "$(can_i "applications/sync/$STACK/$_app")" = yes ] || bad="$bad no-sync-$_app"; done
        rm -f "$ERR_DIR/argo-jail.cfg"
        if [ -n "$bad" ]; then
          warn "argocd: account $ARGO_ACCOUNT is not get+sync-only (tools/kind-stack.sh $STACK up resets its policy):$bad — token deleted, NOT installed"; argo_revoke
        else
          STACK_ARGO_TOKEN="$tok" STACK_ARGO_SERVER="$KIND_CLUSTER-control-plane:$ARGO_NODEPORT"
          ok "argocd: minted 8h token $ARGO_TOKEN_ID for $ARGO_ACCOUNT (get+sync on project $STACK; $STACK_ARGO_SERVER from the jail); deleted at session end"
        fi
      fi
      unset tok
    fi
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
    fail "ABORT dev: could not list $DEV_KUBE_SA permissions — dev credential NOT installed" >&2; sed 's/^/    /' "$ERR_DIR/dev-perms.err"; ok=0
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
    [ -z "$bad" ] || { fail "ABORT dev: $DEV_KUBE_SA is not read-only/secret-free; dev credential NOT installed:"; printf '%s\n' "$bad" | sed 's/^/    /' >&2; ok=0; }
  fi
  if [ $ok = 1 ]; then
    if tok=$(k -n "$DEV_KUBE_NS" create token "$DEV_KUBE_SA" --duration=8h 2>"$ERR_DIR/dev-mint.err" | tr -d '[:space:]') \
       && is_jwt "$tok" && [ "$(jwt_sub "$tok")" = "$as" ]; then
      STACK_DEVKUBE_TOKEN="$tok"
      # DEV_KUBE_SERVER: the API as the proxy container reaches it, when that differs from the host
      # context's view (e.g. kind as a dev stand-in: https://<cluster>-control-plane:6443).
      STACK_DEVKUBE_SERVER=${DEV_KUBE_SERVER:-$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')}
      STACK_DEVKUBE_CA=$(k config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
      ok "dev: minted 8h READ-ONLY token for $DEV_KUBE_SA@$DEV_KUBE_NS (subject verified)"
    else
      warn "dev: mint failed or token failed the gate — continuing without dev kubectl" >&2; [ -s "$ERR_DIR/dev-mint.err" ] && sed 's/^/    /' "$ERR_DIR/dev-mint.err"
    fi
  fi
else
  info "dev: no DEV_KUBE_* in $ENV_FILE — kdev unavailable this session"
fi
export STACK_KUBE_TOKEN STACK_KUBE_SERVER STACK_KUBE_CA STACK_KUBE_NS="$KIND_NS" STACK_KUBE_SA="$KIND_SA"
export STACK_ARGO_SERVER STACK_ARGO_TOKEN
export STACK_DEVKUBE_NS="${DEV_KUBE_NS:-}" STACK_DEVKUBE_SA="${DEV_KUBE_SA:-}"   # the dev token itself never enters the jail

[ -f "$SHARED_CREDS" ] || { warn "$SHARED_CREDS missing — log in once via \`jail-main\` first"; exit 1; }

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
  ok "notes: created $NOTES (local git, no remote)"
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
GITDIRS=(); GITDIR_IDS=()
for r in $REPOS notes; do
  gd="$JAIL_HOME/$STACK/$r/.git"
  [ -d "$gd" ] || { [ -e "$gd" ] && warn "$r/.git is not a directory (worktree/submodule?) — git internals NOT protected"; continue; }
  while IFS= read -r cfg; do
    d="${cfg%/config}"; rel="${d#"$JAIL_HOME/$STACK/"}"
    if [ -e "$d/commondir" ] && [ "$(cat "$d/commondir")" != "." ]; then
      fail "FATAL: $d/commondir points to '$(cat "$d/commondir")' — not a normal clone, or tampered with. Inspect it before launching."; exit 2
    fi
    for f in "$d" "$cfg" "$d/hooks" "$d/commondir"; do      # a dangling symlink here would be written through, on the host
      [ ! -L "$f" ] || { fail "FATAL: $f is a symlink — a gitdir the jail wrote? Inspect it before launching."; exit 2; }
    done
    printf '.\n' > "$d/commondir"
    mkdir -p "$d/hooks"                                      # docker would create a missing source root-owned
    # The gitdir itself is a mount, so it is a mountpoint: the jail cannot rename it away and put
    # a gitdir with a config of its own in its place (renaming a directory that merely CONTAINS the
    # three read-only mounts is allowed, and would have moved them along).
    VOLS+=(-v "$d:/workspace/$rel" -v "$cfg:/workspace/$rel/config:ro" -v "$d/hooks:/workspace/$rel/hooks:ro" -v "$d/commondir:/workspace/$rel/commondir:ro")
    GITDIRS+=("$d"); GITDIR_IDS+=("$(gitdir_id "$d")")
  done < <(find "$gd" -maxdepth 1 -name config -type f; [ -d "$gd/modules" ] && find "$gd/modules" -name config -type f -path '*/modules/*/config')
done

# What mounts cannot cover, checked on the host at start and exit: a nested repository planted in
# a working tree (IDEs auto-detect those and run git in them, with THEIR config), the files git
# would only use for linked worktrees or per-worktree config, and a gitdir or config swapped for
# another one (inode + checksum, recorded at launch). Warn loudly; deleting is the human's call.
# Paths are printed quoted (%q): the jail picks the names, and an escape sequence in one would
# otherwise truncate or erase the warning on the host terminal.
own_submodule() { # <.git entry>: a .git FILE whose gitdir existed at launch (so its config and hooks are mounted read-only)
  local target real g
  [ -f "$1" ] || return 1
  target=$(sed -n 's/^gitdir: //p' "$1"); [ -n "$target" ] || return 1
  real=$(cd "$(dirname "$1")" && cd "$target" 2>/dev/null && pwd -P) || return 1
  for g in ${GITDIRS[@]+"${GITDIRS[@]}"}; do [ "$(cd "$g" && pwd -P)" = "$real" ] && return 0; done
  return 1                                                   # a gitdir made during the session is not a submodule of ours
}
audit_repos() { # <when>
  local r d hits="" i=0
  for r in $REPOS notes; do
    [ -d "$JAIL_HOME/$STACK/$r/.git" ] || continue
    while IFS= read -r d; do
      own_submodule "$d" || hits="$hits"$'\n'"    nested repo: $(printf '%q' "$d")"
    done < <(find "$JAIL_HOME/$STACK/$r" -mindepth 1 \( -path "$JAIL_HOME/$STACK/$r/.git" -prune \) -o \( -name .git -print -prune \) 2>/dev/null)
  done
  for d in ${GITDIRS[@]+"${GITDIRS[@]}"}; do                # bash 3.2 (macOS) + set -u: empty-array safe
    [ "$(cat "$d/commondir" 2>/dev/null)" = "." ] || hits="$hits"$'\n'"    commondir changed: $(printf '%q' "$d/commondir")"
    [ ! -e "$d/config.worktree" ] || hits="$hits"$'\n'"    per-worktree config: $(printf '%q' "$d/config.worktree")"
    [ ! -d "$d/worktrees" ] || hits="$hits"$'\n'"    linked worktrees: $(printf '%q' "$d/worktrees/") (yours?)"
    [ "$(gitdir_id "$d")" = "${GITDIR_IDS[$i]}" ] || hits="$hits"$'\n'"    gitdir or its config replaced: $(printf '%q' "$d")"
    i=$((i + 1))
  done
  [ -z "$hits" ] || warn "git audit ($1) — do NOT run git or open these in an IDE until inspected:$hits"
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
NETNS="jail-$STACK-net"; DEVPROXY="jail-$STACK-devproxy"; GITPROXY="jail-$STACK-gitproxy"; BUILDER="jail-$STACK-builder"; NET="jail-$STACK"
RUN_DIR="$JAIL_HOME/.run-$STACK"; mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"   # sidecar audit logs
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
KUBECTL_IMAGE="${KUBECTL_IMAGE:-registry.k8s.io/kubectl:v1.37.1}"
SIDECAR=(--read-only --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)")

cleanup() {
  local c
  for c in devproxy gitproxy builder; do
    if docker container inspect "jail-$STACK-$c" >/dev/null 2>&1; then
      docker logs "jail-$STACK-$c" > "$RUN_DIR/$c-$(date +%Y%m%dT%H%M%S).log" 2>&1 || true
    fi
  done
  docker rm -f "$DEVPROXY" "$GITPROXY" "$BUILDER" "$NETNS" >/dev/null 2>&1 || true
  rm -f "$RUN_DIR/dev-kubeconfig"
}
on_exit() { cleanup; argo_revoke; audit_repos "after session"; notes_snapshot "after session $(date +%F\ %T)"; rm -rf "$ERR_DIR"; }
trap on_exit EXIT
cleanup                                                           # leftovers of a crashed launch (ERR_DIR stays: the sidecar + gh gates below still write there)

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
# The git sidecar is addressed as www.<host>:8002 (see tools/gitproxy/gitproxy.py for why "www."):
# /etc/hosts belongs to the namespace holder and is shared by everything that joins it.
GITPROXY_PORT=8002
HOSTS_ADD=(--add-host "www.github.com:127.0.0.1")
[ -z "${GITLAB_HOST:-}" ] || HOSTS_ADD+=(--add-host "www.${GITLAB_HOST%%:*}:127.0.0.1")
docker run -d --rm --name "$NETNS" --network "$NET" "${PORTS[@]}" "${HOSTS_ADD[@]}" "${SIDECAR[@]}" "$PAUSE_IMAGE" >/dev/null
if [ -n "$KIND_CLUSTER" ] && docker network inspect "$KIND_NET" >/dev/null 2>&1; then   # reach, not access
  docker network connect "$KIND_NET" "$NETNS" || warn "could not join docker network '$KIND_NET' — kind unreachable"
elif [ -n "$KIND_CLUSTER" ]; then
  warn "docker network '$KIND_NET' does not exist (cluster not created yet?) — kind, its registry and the ingress are unreachable from this jail; relaunch after creating the cluster"
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
    ok "dev: read-only proxy up in the jail's namespace (token stays in $DEVPROXY; audit log → $RUN_DIR/)"
  else
    warn "dev: proxy did not start — continuing without kdev. It said:"
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
    # From each clone's remotes as wired on the host by tools/stack-fork.sh, not from directory
    # names: a local-only dir has no fork, and a same-named repo of another stack in the shared
    # fork org must not land on this stack's lists. The config file is parsed with no system or
    # global config; it is the one the launcher mounts read-only, so the jail never wrote it.
    remote_repo() { # <gitdir> <remote> → owner/repo, lowercase, if the URL is on github.com; else nothing
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$1/config" --get "remote.$2.url" 2>/dev/null \
        | sed -nE 's#^(https?://|git@|ssh://git@)github\.com[:/]##p' | sed -E 's#/+$##; s#\.git$##' | tr '[:upper:]' '[:lower:]' | grep -E '^[^/]+/[^/]+$' || true
    }
    _fork_org=$(printf '%s' "$FORK_ORG" | tr '[:upper:]' '[:lower:]'); _up_owner=$(printf '%s' "${UPSTREAM_OWNER:-}" | tr '[:upper:]' '[:lower:]')
    for r in $REPOS; do
      gd="$JAIL_HOME/$STACK/$r/.git"; [ -d "$gd" ] || continue        # a local-only dir: nothing to push to
      o=$(remote_repo "$gd" origin); u=$(remote_repo "$gd" upstream)
      case "$o" in
        "$_fork_org/"*) GITPROXY_WRITE="$GITPROXY_WRITE,github.com/$o" ;;
        *) warn "git: $r's origin is ${o:-not on github.com}, not a fork in $FORK_ORG — not on the push list (tools/stack-fork.sh $STACK)" ;;
      esac
      case "$u" in
        "") ;;
        "$_up_owner/"*) GITPROXY_READ="$GITPROXY_READ,github.com/$u" ;;
        *) if [ -z "$_up_owner" ]; then GITPROXY_READ="$GITPROXY_READ,github.com/$u"
           else warn "git: $r's upstream is $u, not under UPSTREAM_OWNER=$UPSTREAM_OWNER — the token is not sent there"; fi ;;
      esac
    done
    unset _fork_org _up_owner
  fi
  [ -n "${GITLAB_HOST:-}" ] && [ -n "${GITLAB_FORK_PATH:-}" ] && GITPROXY_WRITE="$GITPROXY_WRITE,$GITLAB_HOST/$GITLAB_FORK_PATH"
  GITPROXY_WRITE="${GITPROXY_WRITE#,}"; GITPROXY_READ="${GITPROXY_READ#,}"
  export GITPROXY_WRITE GITPROXY_READ GITPROXY_LISTEN="127.0.0.1:$GITPROXY_PORT" GH_TOKEN GITLAB_HOST GITLAB_READ_TOKEN GITLAB_FORK_PATH GITLAB_DEPLOY_USER GITLAB_DEPLOY_TOKEN
  docker compose -f "$HERE/docker-compose.yml" run -d --name "$GITPROXY" \
    -e GITPROXY_LISTEN -e GITPROXY_WRITE -e GITPROXY_READ -e GH_TOKEN -e GITLAB_HOST -e GITLAB_READ_TOKEN \
    -e GITLAB_FORK_PATH -e GITLAB_DEPLOY_USER -e GITLAB_DEPLOY_TOKEN gitproxy >/dev/null 2>"$ERR_DIR/gitproxy.err" || true
  for _ in $(seq 1 50); do
    docker logs "$GITPROXY" 2>&1 | grep -q 'gitproxy: serving' && break
    docker container inspect -f '{{.State.Running}}' "$GITPROXY" 2>/dev/null | grep -q true || break
    sleep 0.2
  done
  if docker logs "$GITPROXY" 2>&1 | grep -q 'gitproxy: serving'; then
    STACK_GITPROXY="$GITPROXY_PORT"                                 # the jail reaches it as http://www.<host>:<port>/
    ok "git: credential sidecar up in the jail's namespace (tokens stay in $GITPROXY; GitHub token only for: ${GITPROXY_READ:-<none>} + forks; pushes only to: ${GITPROXY_WRITE:-<none>}; audit log → $RUN_DIR/)"
  else
    warn "git: sidecar did not start — the session has NO git credential (public fetches only). It said:"
    { cat "$ERR_DIR/gitproxy.err"; docker logs "$GITPROXY" 2>&1; } | tail -5 | sed 's/^/    /' >&2
  fi
else
  info "git: no GH_TOKEN and no GITLAB_HOST in $ENV_FILE — no git credential this session"
fi
unset GH_TOKEN GITLAB_READ_TOKEN GITLAB_DEPLOY_USER GITLAB_DEPLOY_TOKEN
export STACK_GITPROXY GITPROXY_WRITE

# ── build: the Paketo lifecycle in a sidecar, pushing under a name allowlist ─────────────────────
# The jail never pushes to a registry (`docker push` is denied, and there is no docker in there).
# If the stack names a builder, a sidecar made from it (tools/builder/) runs the CNB lifecycle in
# the jail's network namespace against requests the jail drops into the shared build directory,
# and pushes the image and the chart to the stack's kind registry. Only names in BUILD_NAMES; the
# push credential, if the registry wants one, goes to the sidecar and never to the jail. The
# protocol is in tools/builder/builder.sh; the jail side is tools/build-image.
STACK_BUILD_DIR="" STACK_BUILD_REGISTRY="" STACK_BUILD_NAMES=""
if [ -n "${BUILDER_IMAGE:-}" ]; then
  BUILD_NAMES="${BUILD_NAMES:-}"; BUILD_REGISTRY="${BUILD_REGISTRY:-jail-$STACK-registry:5000}"   # tools/kind-stack.sh's registry
  BUILD_HOST_DIR="$JAIL_HOME/$STACK/build"; mkdir -p "$BUILD_HOST_DIR/.workspace" "$BUILD_HOST_DIR/.layers"   # pack's /workspace and /layers, see builder.sh
  # shellcheck disable=SC2086  # ${BUILDER_PULL:+--pull} below is one optional word
  if [ -z "$BUILD_NAMES" ]; then
    warn "build: BUILDER_IMAGE is set but BUILD_NAMES is empty in stacks/$STACK.conf — no sidecar (it could push nothing)"
  elif ! docker build -q ${BUILDER_PULL:+--pull} --build-arg "BUILDER_IMAGE=$BUILDER_IMAGE" --build-arg "HELM_VERSION=${HELM_VERSION:-latest}" \
          -t "$BUILDER" "$HERE/tools/builder" >/dev/null 2>"$ERR_DIR/builder-build.err"; then   # BUILDER_PULL=1: --pull (refresh a moving builder tag); otherwise the cache is the point
    warn "build: could not build the sidecar image from $BUILDER_IMAGE — no build-image this session. docker said:"
    tail -5 "$ERR_DIR/builder-build.err" | sed 's/^/    /' >&2
  else
    # Platform API the lifecycle must speak: the highest the builder supports, from its own label
    # (io.buildpacks.lifecycle.apis — what pack reads too); the conf's BUILDER_PLATFORM_API overrides.
    if [ -z "${BUILDER_PLATFORM_API:-}" ]; then
      builder_label() { docker image inspect "$BUILDER" -f "{{index .Config.Labels \"$1\"}}" 2>/dev/null; }
      BUILDER_PLATFORM_API=$( { builder_label io.buildpacks.lifecycle.apis | jq -r '.platform.supported[]? // empty';
                                builder_label io.buildpacks.builder.metadata | jq -r '.lifecycle.apis.platform.supported[]?, (.lifecycle.api.platform // empty)'; } 2>/dev/null \
                              | grep -E '^[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n | tail -1) || BUILDER_PLATFORM_API=""
      [ -n "$BUILDER_PLATFORM_API" ] || warn "build: no platform API in the builder's labels (has: $(docker image inspect "$BUILDER" -f '{{range $k, $v := .Config.Labels}}{{$k}} {{end}}' 2>/dev/null)) — set BUILDER_PLATFORM_API in stacks/$STACK.conf"
    fi
    docker run -d --name "$BUILDER" --network "container:$NETNS" "${SIDECAR[@]}" --tmpfs /tmp -e HOME=/tmp \
      -v "$BUILD_HOST_DIR:/build" -v "$BUILD_HOST_DIR/.workspace:/workspace" -v "$BUILD_HOST_DIR/.layers:/layers" \
      -e "BUILD_REGISTRY=$BUILD_REGISTRY" -e "BUILD_NAMES=$BUILD_NAMES" \
      -e "BUILDER_RUN_IMAGE=${BUILDER_RUN_IMAGE:-}" -e "BUILDER_PLATFORM_API=${BUILDER_PLATFORM_API:-}" -e REGISTRY_PUSH_USER -e REGISTRY_PUSH_PASSWORD "$BUILDER" >/dev/null
    for _ in $(seq 1 50); do
      docker logs "$BUILDER" 2>&1 | grep -q 'jail-builder: serving' && break
      docker container inspect -f '{{.State.Running}}' "$BUILDER" 2>/dev/null | grep -q true || break
      sleep 0.2
    done
    if docker logs "$BUILDER" 2>&1 | grep -q 'jail-builder: serving'; then
      STACK_BUILD_DIR="/workspace/build" STACK_BUILD_REGISTRY="$BUILD_REGISTRY" STACK_BUILD_NAMES="$BUILD_NAMES"
      VOLS+=(-v "$BUILD_HOST_DIR:/workspace/build")
      ok "build: sidecar up from $BUILDER_IMAGE (platform API ${BUILDER_PLATFORM_API:-per the descriptor}; pushes only [${BUILD_NAMES}] to $BUILD_REGISTRY; credential: $([ -n "${REGISTRY_PUSH_USER:-}" ] && echo "in $BUILDER only" || echo "none"); requests: $BUILD_HOST_DIR; audit log → $RUN_DIR/)"
      # Is the allowlist a boundary? Only if the registry refuses anonymous pushes (tools/kind-stack.sh
      # puts Zot's policy there). Checkable from the host when the registry is published on loopback.
      if [ -n "${REGISTRY_PORT:-}" ]; then
        _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "http://127.0.0.1:$REGISTRY_PORT/v2/${BUILD_NAMES%% *}/blobs/uploads/" 2>/dev/null) || _code=000
        case "$_code" in
          401) ok "build: registry refuses anonymous pushes — only the sidecar (its credential, its allowlist) can push"
               [ -n "${REGISTRY_PUSH_USER:-}" ] || warn "build: …but REGISTRY_PUSH_USER is empty in $ENV_FILE, so the sidecar cannot push either (tools/kind-stack.sh $STACK up writes one)" ;;
          000) warn "build: registry not answering on 127.0.0.1:$REGISTRY_PORT — pushes will fail" ;;
          *)   warn "build: registry ACCEPTS anonymous pushes (HTTP $_code) — the sidecar's allowlist is not a boundary this session (tools/kind-stack.sh $STACK up)" ;;
        esac
      else
        info "build: registry push policy unverified from the host (no REGISTRY_PORT in the conf)"
      fi
    else
      warn "build: sidecar did not start — no build-image this session. It said:"
      docker logs "$BUILDER" 2>&1 | tail -5 | sed 's/^/    /' >&2
    fi
  fi
else
  info "build: no BUILDER_IMAGE in stacks/$STACK.conf — build-image unavailable this session"
fi
unset REGISTRY_PUSH_USER REGISTRY_PUSH_PASSWORD
export STACK_BUILD_DIR STACK_BUILD_REGISTRY STACK_BUILD_NAMES

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
  case "$GH_PUBLIC_TOKEN" in github_pat_*) ;; *) fail "ABORT gh: GH_PUBLIC_TOKEN is not a fine-grained token (github_pat_…) — NOT installed"; GH_PUBLIC_TOKEN=unverifiable ;; esac
  if [ "$GH_PUBLIC_TOKEN" != unverifiable ]; then
    # Any failure (network, non-JSON) leaves the variables empty / "?" and refuses: fail closed, not out.
    login=$(gh_api user | jq -r '.login // empty' 2>/dev/null) || login=""
    private=$(gh_api 'user/repos?visibility=private&per_page=1' | jq -r 'if type == "array" then length else "?" end' 2>/dev/null) || private="?"
    if [ -z "$login" ]; then
      fail "ABORT gh: GH_PUBLIC_TOKEN is not valid or api.github.com is unreachable (GET /user failed) — NOT installed" >&2; sed 's/^/    /' "$ERR_DIR/gh-public.err"
    elif [ "$private" != 0 ]; then
      fail "ABORT gh: GH_PUBLIC_TOKEN can see private repositories (or the probe failed: '$private') — NOT installed"
    else
      GH_TOKEN="$GH_PUBLIC_TOKEN"
      ok "gh: public-read-only token for $login enters the jail (authenticated rate limit; writes are refused by GitHub)"
    fi
  fi
  rm -f "$ERR_DIR/gh-curl.cfg"
else
  info "gh: no GH_PUBLIC_TOKEN in $ENV_FILE — gh is unauthenticated in the jail (anonymous rate limit)"
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
  -e STACK_BUILD_DIR -e STACK_BUILD_REGISTRY -e STACK_BUILD_NAMES -e STACK_ARGO_SERVER -e STACK_ARGO_TOKEN \
  stack \
  bash -c "source /workspace/tools/stack-jail-init.sh && cd /workspace/$PRIMARY && exec claude ${JAIL_CLAUDE_FLAGS:-}"

}
main "$@"
