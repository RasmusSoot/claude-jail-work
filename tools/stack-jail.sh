#!/usr/bin/env bash
# stack-jail — host-side launcher for a per-stack jail (the credential airlock).
#
#   stack-jail.sh <stack> [--login]
#   stack-jail.sh <stack> --adopt [<dir>/.git …]   record gitdirs the human made on the host (see "Terms" below)
#   stack-jail.sh <stack> --second                 a second Claude in the RUNNING jail: notes only (tools/second-jail.md)
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
ADOPT=0; ADOPT_PATHS=(); if [ "${1:-}" = "--adopt" ]; then ADOPT=1; shift; ADOPT_PATHS=("$@"); fi   # record named gitdirs, then exit
SECOND=0; [ "${1:-}" = "--second" ] && SECOND=1
[ -n "$STACK" ] || { echo "usage: stack-jail.sh <stack> [--login | --adopt [<dir>/.git …] | --second]" >&2; exit 2; }

CONF="$HERE/stacks/$STACK.conf"
[ -f "$CONF" ] || { fail "FATAL: $CONF missing — add a stacks/<stack>.conf (see stacks/siva.conf)"; exit 2; }
# shellcheck source=/dev/null
. "$CONF"
: "${REPOS:?stacks/$STACK.conf must set REPOS}" "${PRIMARY:?must set PRIMARY}" "${UPLOAD_PORT:?must set UPLOAD_PORT}"
for r in $REPOS; do case "$r" in notes|build|tools) fail "FATAL: stacks/$STACK.conf lists a repo named '$r' — /workspace/$r is the stack's $r mount"; exit 2;; esac; done
# --second: another Claude process inside the jail that is already running — no lock, no gates, no
# mints, no mounts, no sidecars: it joins what the first launch set up and dies with it (the jail's
# main process is the first session). Its init (STACK_JAIL_SECOND) only exports — the first one's
# files are live, a rewrite would race them — and it gets tools/second-jail.md as its rules: read the repos and
# clusters, write only notes/, no git writes, no pushes. Those rules are discipline, not a boundary;
# the boundary is that it holds nothing the first session does not.
if [ "$SECOND" = 1 ]; then
  [ "$(docker container inspect -f '{{.State.Running}}' "jail-$STACK" 2>/dev/null)" = true ] \
    || { fail "FATAL: jail-$STACK is not running — start it first ($STACK), then $STACK --second"; exit 2; }
  exec docker exec -it -w "/workspace/$PRIMARY" "jail-$STACK" \
    bash -c 'r=$(cat /workspace/tools/second-jail.md) || exit 2; export STACK_JAIL_SECOND=1; source /workspace/tools/stack-jail-init.sh && exec claude --append-system-prompt "$r" '"${JAIL_CLAUDE_FLAGS:-}"   # no rules file, no session
fi
for _c in "$HERE"/stacks/*.conf; do                 # a host port is one stack's: a clash would surface only at `docker run`, after the mints
  [ "$_c" != "$CONF" ] || continue
  _u=$(sed -n 's/^UPLOAD_PORT=\([0-9]*\).*/\1/p' "$_c" | head -1); _r=$(sed -n 's/^REGISTRY_PORT=\([0-9]*\).*/\1/p' "$_c" | head -1)
  [ "$_u" != "$UPLOAD_PORT" ] || { fail "FATAL: UPLOAD_PORT=$UPLOAD_PORT is also $(basename "$_c")'s — give one of them another port"; exit 2; }
  [ -z "${REGISTRY_PORT:-}" ] || [ "$_r" != "$REGISTRY_PORT" ] || { fail "FATAL: REGISTRY_PORT=$REGISTRY_PORT is also $(basename "$_c")'s — give one of them another port"; exit 2; }
done; unset _c _u _r
KIND_CLUSTER="${KIND_CLUSTER-$STACK}"               # conf may set KIND_CLUSTER="" = no kind for this stack
KIND_NET="${KIND_NET:-kind}"                        # docker network the kind nodes sit on
KIND_NS="${KIND_NS:-$STACK}"
KIND_SA="${KIND_SA:-$STACK-workbench}"

ENV_FILE="$JAIL_HOME/.env.$STACK"
STATE_DIR="$JAIL_HOME/.claude-data-$STACK"
CLAUDE_JSON="$JAIL_HOME/.claude-data-$STACK.json"
SHARED_CREDS="$JAIL_HOME/.claude-data/.credentials.json"   # login once via `jail-main`
RUN_DIR="$JAIL_HOME/.run-$STACK"; mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"   # host-only, never mounted: sidecar audit logs, the gitdir record, the builder's work dirs
GITDIR_RECORD="$RUN_DIR/gitdirs"                     # see "Terms" below

mkdir -p "$STATE_DIR" "$JAIL_HOME/$STACK"
[ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"
for r in $REPOS; do
  [ -d "$JAIL_HOME/$STACK/$r" ] || warn "$JAIL_HOME/$STACK/$r missing — run tools/stack-fork.sh $STACK first"
done
[ -d "$JAIL_HOME/$STACK/$PRIMARY" ] || { fail "FATAL: the primary dir $PRIMARY is missing — run tools/stack-fork.sh $STACK (or mkdir it, if it is a local-only dir)"; exit 2; }
[ "$ADOPT" = 1 ] || jq -e 'length > 0' "$SHARED_CREDS" >/dev/null 2>&1 \
  || { fail "FATAL: $SHARED_CREDS is missing or empty (setup-env.sh leaves a placeholder) — log in once via \`jail-main\` first (nothing is minted without it)"; exit 1; }

# Terms. A REPO DIR is a REPOS entry, ~/claude/jail/<stack>/<name>, mounted rw at /workspace/<name>;
# the conf decides that and it says nothing about git. A GITDIR is <repo dir>/.git as a directory —
# the only kind there is here: a .git pointer file or symlink, or a .git/modules dir (submodules),
# stops the launch (tools/gitdir-scan.sh says why). A RECORDED GITDIR is one listed with its inode
# in $RUN_DIR/gitdirs — by tools/stack-fork.sh for the clones it makes, by this launcher for the
# notes repo it creates, and by `--adopt <dir>/.git` for what the human made on the host and has
# looked at — and only a recorded gitdir is mounted protected, has its remotes read for the push
# list, and is not an audit hit. A LOCAL-ONLY DIR is a repo dir with no recorded gitdir, and it
# stays one if a .git appears in it. A gitdir on disk that is not recorded, or whose inode differs
# from the record, is a PLANTED GITDIR until the human says otherwise: it stops the launch here,
# before any token is minted, and the exit audit reports it the same day. Against the jail the
# record is exact: a repo dir and its gitdir are both mountpoints there, so a session can neither
# rename nor replace them, and a gitdir absent at any launch is pruned from the record, so one a
# session makes at that path later is unrecorded. The inode is for the host side: a directory
# replaced by hand with no launch in between shows as "replaced" (unless the filesystem reused the
# inode, which only the human's own re-clone can bring about: accepted). Trust comes from the
# record, never from presence on disk: the jail writes the disk.
gitdir_scan() { # → the scan's lines on stdout, or a non-zero exit: a scan that did not run to its "end" line is no scan
  local out; out=$(mktemp) || return 1
  # shellcheck disable=SC2086  # REPOS is a word list, split on purpose
  if ! bash "$HERE/tools/gitdir-scan.sh" "$JAIL_HOME/$STACK" $REPOS notes build > "$out" 2>"$out.err" || [ "$(tail -n 1 "$out")" != end ]; then
    fail "gitdir scan did not run (tools/gitdir-scan.sh): $(head -c 300 "$out.err" | tr '\n' ' ')"; rm -f "$out" "$out.err"; return 1
  fi
  sed '$d' "$out"; rm -f "$out" "$out.err"
}
# One actor per stack at a time: this launch, a `--adopt`, or tools/stack-fork.sh. The lock is a
# directory (mkdir is atomic, POSIX, macOS too) held until exit; the holder check behind it is for
# the session itself, which outlives the launcher's gates. Without both, a second launch would scan
# a tree the first session is writing, and its cleanup would tear the first session's sidecars down.
LOCK="$RUN_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  fail "FATAL: $LOCK exists — another $STACK launch, --adopt or stack-fork.sh is running. If none is (a crashed one left it): rmdir $LOCK"; exit 2
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT                     # the later traps keep this
session_running() { # the namespace holder, or the jail itself (it can outlive a killed launcher, with its rw mounts)
  docker container inspect -f '{{.State.Running}}' "jail-$STACK-net" "jail-$STACK" 2>/dev/null | grep -q true
}
if session_running; then
  fail "FATAL: a $STACK session is running (jail-$STACK or jail-$STACK-net): one at a time — the tree is being written while this would scan and mount it. If that session is gone and only its containers linger: docker rm -f jail-$STACK jail-$STACK-net"; exit 2
fi
record_prune "$GITDIR_RECORD" "$JAIL_HOME/$STACK"
GITDIR_RELS=(); _unrec=""; _refuse=""; _adoptable=""
_scan=$(gitdir_scan) || { fail "FATAL: no gitdir scan, no launch"; exit 2; }
while IFS=$'\t' read -r _kind _p _x; do
  case "$_kind" in
    gitdir) if record_has "$GITDIR_RECORD" "$_p" "$_x"; then GITDIR_RELS+=("$_p")
            elif record_line "$GITDIR_RECORD" "$_p"; then _unrec="$_unrec"$'\n'"    $(printf '%q' "$_p")  (recorded, but replaced since: a different directory)"; _adoptable="$_adoptable $(printf '%q' "$_p")"
            else _unrec="$_unrec"$'\n'"    $(printf '%q' "$_p")  (not recorded)"; _adoptable="$_adoptable $(printf '%q' "$_p")"; fi ;;
    refuse) _refuse="$_refuse"$'\n'"    $(printf '%q' "$_p"): $_x" ;;
  esac
done <<< "$_scan"
if [ "$ADOPT" = 1 ]; then
  [ -z "$_refuse" ] || { fail "FATAL: nothing can be adopted while these exist (remove or fix them first):$_refuse"; exit 2; }
  if [ ${#ADOPT_PATHS[@]} -eq 0 ]; then
    if [ -z "$_unrec" ]; then ok "git: every gitdir on disk is in $GITDIR_RECORD — nothing to adopt"; exit 0; fi
    fail "--adopt takes the gitdirs to record, by name, after you have looked at each one's config and hooks (nothing has run them). Candidates:$_unrec"
    printf '    tools/stack-jail.sh %s --adopt%s\n' "$STACK" "$_adoptable" >&2; exit 2
  fi
  for _p in "${ADOPT_PATHS[@]}"; do
    _p="${_p%/}"; _p="${_p#./}"
    _x=$(printf '%s\n' "$_scan" | awk -F'\t' -v p="$_p" '$1 == "gitdir" && $2 == p { print $3 }')
    [ -n "$_x" ] || { fail "FATAL: $(printf '%q' "$_p") is not a top-level .git directory of a listed dir (candidates:$_unrec)"; exit 2; }
    record_add "$GITDIR_RECORD" "$_p" "$_x" && ok "git: recorded $(printf '%q' "$_p") (inode $_x) in $GITDIR_RECORD — its config, hooks and commondir are read-only in the jail from the next launch"
  done
  exit 0
fi
[ -z "$_refuse" ] || { fail "FATAL: git state the jail must not see (tools/gitdir-scan.sh) — made by a session, or by hand? Inspect, then remove or fix it:$_refuse"; exit 2; }
if [ -n "$_unrec" ]; then
  fail "FATAL: gitdirs on disk that are not in $GITDIR_RECORD — new on the host (git init, a clone by hand), or planted by a session? Inspect each one's config and hooks (nothing has run them), then record what is yours:$_unrec"
  printf '    tools/stack-jail.sh %s --adopt%s\n' "$STACK" "$_adoptable" >&2; exit 2
fi
unset _unrec _refuse _adoptable _kind _p _x _scan
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
JAIL_ALLOW="$JAIL_ALLOW" python3 -I - "$JAIL_HOME/.claude-data/settings.json" "$STATE_DIR/settings.json" <<'PY'
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
python3 -I - "$CLAUDE_JSON" "$JAIL_HOME/.claude-data.json" $TRUST_DIRS <<'PY'
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
argo_revoke() { :; }; ARGO_DISABLED=0
ERR_DIR=$(mktemp -d); trap 'argo_revoke || true; rm -rf "$ERR_DIR"; rmdir "$LOCK" 2>/dev/null' EXIT   # mint stderr; no fixed /tmp names (cleanup() takes over later)
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
# must not be able to take that away: no patch/update/delete of any namespace, no creating
# namespaces (a fresh one would have no label), no kubelet reach, nothing beyond read-only where
# there is no label, and no shell subresource in any labelled namespace but its own. The label, the SA
# and its RoleBinding are applied by tools/kind-stack.sh <stack> up (host-side, from the conf):
#   pod-security.kubernetes.io/enforce: baseline     # or restricted
rules_not_readonly() { # stdin: `kubectl auth can-i --list` output → every row allowing more than get/list/watch, or any secrets read
  # Rows: "<resource> [<non-resource URLs>] [<resource names>] [<verbs>]"; non-resource rows have
  # no resource column. Verbs = the LAST bracket group (it may contain spaces).
  awk '
    NR == 1 || NF == 0 { next }                                # header
    !match($0, /\[[^][]*\]$/) { print "unparseable: " $0; next }
    { verbs = substr($0, RSTART + 1, RLENGTH - 2); res = ($1 ~ /^\[/) ? "(non-resource) " $1 : $1 }
    # SelfSubject*Review creates are what can-i itself uses; they are not writes.
    res ~ /^selfsubject(access|rules)?reviews\.(authorization|authentication)\.k8s\.io$/ && verbs == "create" { next }
    res ~ /\/(proxy|exec|attach|portforward|ephemeralcontainers)$/ { print res " [" verbs "] (a shell or the kubelet, whatever the verb)"; next }
    { n = split(verbs, v, " "); for (i = 1; i <= n; i++) if (v[i] !~ /^(get|list|watch)$/) { print res " [" verbs "]"; next } }
    res ~ /^(\*|\*\.\*|secrets(\..*)?)$/ { print res " [" verbs "] (covers secrets)" }   # any read of secrets leaks them
  '
}
rules_write_namespaces() { # stdin: the same → rows that let the subject patch/update/delete namespaces (the Pod Security label),
                           # or reach the kubelet (nodes/proxy with any verb; nodes is cluster-scoped, so it shows in every namespace's list)
  awk '
    NR == 1 || NF == 0 { next }
    !match($0, /\[[^][]*\]$/) { print "unparseable: " $0; next }
    { verbs = substr($0, RSTART + 1, RLENGTH - 2) }
    $1 ~ /^(namespaces|\*|\*\.\*)$/ && verbs ~ /(^| )(patch|update|delete|\*)( |$)/ { print $1 " [" verbs "]"; next }
    $1 ~ /^nodes\/proxy$/ { print $1 " [" verbs "] (the kubelet API: exec past Pod Security)"; next }
    $1 ~ /^nodes$/ && verbs ~ /(^| )(patch|update|delete|create|\*)( |$)/ { print $1 " [" verbs "]" }
  '
}
kind_psa_gate() {
  local kk=(kubectl --context "kind-$KIND_CLUSTER") as="system:serviceaccount:$KIND_NS:$KIND_SA" psa bad=""
  # A failed read is not "label unset": the API may be down or the namespace missing. Say which.
  if ! psa=$("${kk[@]}" get ns "$KIND_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>"$ERR_DIR/kind-ns.err"); then
    fail "kind gate REFUSED: cannot read namespace $KIND_NS on kind-$KIND_CLUSTER (cluster down? namespace missing?). kubectl said:"
    sed 's/^/    /' "$ERR_DIR/kind-ns.err" | head -3 >&2; return 1
  fi
  case "$psa" in
    baseline|restricted) ;;
    *) fail "kind gate REFUSED: namespace $KIND_NS has pod-security.kubernetes.io/enforce='${psa:-<unset>}' — needs baseline or restricted"; return 1 ;;
  esac
  # A request on namespaces/<ns> is evaluated WITH namespace=<ns>, so RoleBindings inside that
  # namespace count: ask with -n, or a binding there (one a pushed chart made Argo create, say)
  # is never consulted and the gate passes a SA that can drop the label.
  for v in patch update delete; do
    [ "$("${kk[@]}" auth can-i "$v" "namespace/$KIND_NS" -n "$KIND_NS" --as="$as" 2>/dev/null)" = no ] || bad="$bad $v-namespace/$KIND_NS"
  done
  [ "$("${kk[@]}" auth can-i create namespaces --as="$as" 2>/dev/null)" = no ] || bad="$bad create-namespaces"
  # Every namespace, one at a time (--all-namespaces answers "no" as soon as a single namespace is
  # out of reach, which hides a grant in `default`), from the SA's whole rule list there: WITHOUT a
  # Pod Security label it must be read-only and secret-free (not just "no create pods": a
  # Deployment, Job, pods/exec or an ephemeral container runs a privileged container just as well);
  # WITH one, nothing may patch/update/delete namespaces (that is the label) or reach the kubelet
  # (nodes/proxy; a cluster-wide grant shows in every namespace's list, and kubelet exec bypasses
  # Pod Security); in the STACK namespace pods/exec etc. are fine (namespace-admin by design, the
  # label bounds what a pod there can be), in any other labelled namespace a shell subresource is
  # refused too (an exec into a pod of argocd's, say, is a cluster-admin shell). A namespace list
  # that fails or comes back empty refuses too: no list, no gate.
  local ns lbl nslist perms v
  if ! nslist=$("${kk[@]}" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}' 2>"$ERR_DIR/kind-ns.err") || [ -z "$nslist" ]; then
    fail "kind gate REFUSED: cannot list namespaces on kind-$KIND_CLUSTER. kubectl said:"; sed 's/^/    /' "$ERR_DIR/kind-ns.err" | head -3 >&2; return 1
  fi
  while IFS=$'\t' read -r ns lbl; do
    [ -n "$ns" ] || continue
    if ! perms=$("${kk[@]}" auth can-i --list -n "$ns" --as="$as" 2>/dev/null); then bad="$bad no-rule-list-for-$ns"; continue; fi
    case "$lbl" in
      baseline|restricted)
        if [ "$ns" = "$KIND_NS" ]; then v=$(printf '%s\n' "$perms" | rules_write_namespaces | head -1)
        else v=$( { printf '%s\n' "$perms" | rules_write_namespaces; printf '%s\n' "$perms" | rules_not_readonly | grep -F 'a shell or the kubelet'; } | head -1); fi ;;
      *) v=$(printf '%s\n' "$perms" | rules_not_readonly | head -1) ;;
    esac
    [ -z "$v" ] || bad="$bad $ns:[$v]"
  done <<< "$nslist"
  # A Service with externalIPs makes kube-proxy route traffic for that address — the node's own, say —
  # to a pod of the SA's choosing, ahead of the NodePort (the CVE-2020-8554 pattern). The admin login
  # above verifies TLS, so a capture gets nothing, but none may exist, and the cluster should refuse
  # them outright (DenyServiceExternalIPs, set by tools/kind-stack.sh at create time).
  local ext
  ext=$("${kk[@]}" get svc -A -o jsonpath='{range .items[?(@.spec.externalIPs)]}{.metadata.namespace}/{.metadata.name}{" "}{end}' 2>/dev/null) || ext="?"
  [ -z "$ext" ] || bad="$bad services-with-externalIPs:[${ext% }]"
  local plugins
  plugins=$("${kk[@]}" -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[*].spec.containers[*].command[*]}' 2>/dev/null | tr ' ' '\n' | sed -n 's/^--enable-admission-plugins=//p' | head -1) || plugins=""
  case ",$plugins," in *,DenyServiceExternalIPs,*) ;; *) warn "kind: the API server does not run the DenyServiceExternalIPs admission plugin (enabled: '${plugins:-?}'; a cluster created before it was added?) — recreate it when convenient: tools/kind-stack.sh $STACK down && tools/kind-stack.sh $STACK up" ;; esac
  case ",$plugins," in *,NodeRestriction,*) ;; *) bad="$bad no-NodeRestriction-admission(enabled:'${plugins:-?}')" ;; esac
  [ -z "$bad" ] || { fail "kind gate REFUSED: $KIND_SA could undo the Pod Security label or run workloads outside it:$bad"; return 1; }
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
# write it must not have (app create/update/delete/override, update of any account — its own tokens an account may always mint, which the disable-at-exit covers,
# repository create, project update) has to answer "no" and sync "yes". Deleted again at session end.
STACK_ARGO_SERVER="" STACK_ARGO_TOKEN="" ARGO_TOKEN_ID="" ARGO_URL=""
ARGO_ACCOUNT="$STACK-jail"; ARGO_NODEPORT="${ARGO_NODEPORT:-30443}"
# TLS is VERIFIED here, unlike the jail's own argocd calls: the admin password goes over this connection.
# The trust anchor is the server's certificate read through the API server (whose TLS the host
# kubeconfig verifies), and --resolve pins the name in that certificate to the node's address, so a
# Service with externalIPs (which a namespace admin may create, and kube-proxy honours before the
# NodePort) that captured the connection could not answer with a certificate curl accepts.
argo_api() { curl -sS --fail-with-body --max-time 15 --cacert "$ERR_DIR/argo-ca.pem" --resolve "$ARGO_RESOLVE" -K "$ERR_DIR/argo-$1.cfg" -H 'Content-Type: application/json' "${@:2}" 2>>"$ERR_DIR/argo.err"; }
argo_account_enabled() { # <true|false>: a disabled local account's tokens are all refused at once — the kill switch
  kubectl --context "kind-$KIND_CLUSTER" -n argocd patch cm argocd-cm --type merge -p "{\"data\":{\"accounts.$ARGO_ACCOUNT.enabled\":\"$1\"}}" >/dev/null 2>>"$ERR_DIR/argo.err"
}
argo_admin_login() { # → $ERR_DIR/argo-admin.cfg holds a fresh admin session; 1 if Argo is not reachable, its certificate is not readable, or the login fails
  local node_ip admin_pw sess crt
  node_ip=$(docker container inspect -f "{{with index .NetworkSettings.Networks \"$KIND_NET\"}}{{.IPAddress}}{{end}}" "$KIND_CLUSTER-control-plane" 2>/dev/null) || node_ip=""
  admin_pw=$(kubectl --context "kind-$KIND_CLUSTER" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>"$ERR_DIR/argo.err" | base64 -d) || admin_pw=""
  # The server's certificate: a human-provided one (argocd-server-tls) or the self-signed one Argo keeps in argocd-secret
  crt=$(kubectl --context "kind-$KIND_CLUSTER" -n argocd get secret argocd-server-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null) || crt=""
  [ -n "$crt" ] || crt=$(kubectl --context "kind-$KIND_CLUSTER" -n argocd get secret argocd-secret -o jsonpath='{.data.tls\.crt}' 2>>"$ERR_DIR/argo.err") || crt=""
  [ -n "$node_ip" ] && [ -n "$admin_pw" ] && [ -n "$crt" ] || { echo "no node address, admin password or server certificate" >> "$ERR_DIR/argo.err"; return 1; }
  ( umask 077; printf '%s' "$crt" | base64 -d > "$ERR_DIR/argo-ca.pem" )
  ARGO_URL="https://argocd-server:$ARGO_NODEPORT"; ARGO_RESOLVE="argocd-server:$ARGO_NODEPORT:$node_ip"   # the name is in Argo's self-signed certificate
  ( umask 077; : > "$ERR_DIR/argo-none.cfg" )                   # the password travels on stdin (to jq, then to curl), never argv
  sess=$(printf '%s' "$admin_pw" | jq -n --rawfile p /dev/stdin '{username:"admin",password:$p}' | argo_api none -X POST "$ARGO_URL/api/v1/session" -d @- | jq -r '.token // empty' 2>/dev/null) || sess=""
  [ -n "$sess" ] || return 1
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$sess" > "$ERR_DIR/argo-admin.cfg" )
}
argo_revoke() { # [keep]: EVERY token of the stack's account, not just this launch's — Argo CD lets an account manage its
                # own tokens, so a session could mint itself a longer one; it dies here, at launch and at session end.
                # Loud when it cannot: a silent failure would look like "no tokens". At exit the admin session from the
                # launch may have expired (24h), so it logs in again unless told to keep the one it has.
  [ -n "${ARGO_URL:-}" ] && [ -d "${ERR_DIR:-/nonexistent}" ] || return 0          # Argo was never reached this launch
  local acct ids id n=0 all=0 rc=0 by_hand="delete them by hand: tools/kind-stack.sh $STACK ui → Settings → Accounts → $ARGO_ACCOUNT (the next launch deletes them too)"
  # The kill switch first, through the API server: a disabled account's tokens are refused at once,
  # every one of them — including one a pod mints after the list below is read (the list is a
  # snapshot; disabling is not). The account stays disabled until the next launch re-enables it.
  if argo_account_enabled false; then
    ARGO_DISABLED=1; if [ "${1:-}" = keep ]; then ok "argocd: account $ARGO_ACCOUNT disabled while its tokens are cleared"; else ok "argocd: account $ARGO_ACCOUNT disabled until the next launch"; fi
  else ARGO_DISABLED=0; warn "argocd: could not disable account $ARGO_ACCOUNT (argocd-cm) — its tokens stay valid until deleted; $by_hand"; rc=1; fi
  if [ "${1:-}" != keep ] && ! argo_admin_login; then
    warn "argocd: cannot log in at $ARGO_URL as admin — the tokens of $ARGO_ACCOUNT were NOT deleted; $by_hand"; ARGO_TOKEN_ID=""; return 1
  fi
  acct=$(argo_api admin "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT") || acct=""
  if [ "$(printf '%s' "$acct" | jq -r '.name // empty' 2>/dev/null)" != "$ARGO_ACCOUNT" ]; then
    warn "argocd: could not read account $ARGO_ACCOUNT (tokens NOT deleted; $by_hand). It said: $(printf '%s' "$acct" | head -c 200)"; ARGO_TOKEN_ID=""; return 1
  fi
  ids=$(printf '%s' "$acct" | jq -r '.tokens[]?.id | @uri' 2>/dev/null) || ids=""
  for id in $ids; do all=$((all + 1)); argo_api admin -X DELETE "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT/token/$id" >/dev/null && n=$((n + 1)); done   # --fail-with-body: a 404 or 5xx does not count
  # What counts is what the account says afterwards, not the DELETE tally: a token whose id the
  # route cannot address (a session may choose the id) would otherwise be "deleted" and come back
  # alive when the launch re-enables the account.
  local left
  left=$(argo_api admin "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT" | jq -r 'select(.name == $a) | .tokens | length' --arg a "$ARGO_ACCOUNT" 2>/dev/null) || left=""
  if [ "$left" = 0 ]; then
    [ "$all" = 0 ] || ok "argocd: $n token(s) of $ARGO_ACCOUNT deleted${ARGO_TOKEN_ID:+ (the session token and any minted during the session)}"
  else
    warn "argocd: ${left:-?} token(s) of $ARGO_ACCOUNT remain after deleting $n of $all — $by_hand"; rc=1
  fi
  ARGO_TOKEN_ID=""
  return $rc
}
if [ -z "${ARGO_APPS:-}" ]; then
  info "argocd: no ARGO_APPS in stacks/$STACK.conf — argocd unavailable this session"
elif [ -z "$STACK_KUBE_TOKEN" ]; then
  warn "argocd: skipped — no kind token this session"
else
  if ! argo_admin_login; then
    warn "argocd: not installed on kind-$KIND_CLUSTER, not reachable on '$KIND_NET', or the admin login failed (tools/kind-stack.sh $STACK up) — continuing without argocd. It said:"; tail -3 "$ERR_DIR/argo.err" | sed 's/^/    /' >&2
    ARGO_URL=""                                                  # nothing to revoke at exit either
  else
    # Disable → delete every token → enable → mint. A launch that cannot clear the account does
    # not mint: an old token would stay alive next to the new one.
    if ! argo_revoke keep; then
      warn "argocd: the account's tokens could not be cleared — continuing without argocd ($([ "${ARGO_DISABLED:-0}" = 1 ] && echo "the account stays disabled" || echo "and the account could NOT be disabled: delete its tokens by hand, tools/kind-stack.sh $STACK ui"))"
    elif ! argo_account_enabled true; then
      warn "argocd: could not re-enable account $ARGO_ACCOUNT (argocd-cm) — continuing without argocd"
    else
      ARGO_TOKEN_ID="jail-$(date +%Y%m%dT%H%M%S)"
      tok=$(jq -n --arg id "$ARGO_TOKEN_ID" '{expiresIn: 28800, id: $id}' \
            | argo_api admin -X POST "$ARGO_URL/api/v1/account/$ARGO_ACCOUNT/token" -d @- | jq -r '.token // empty' 2>/dev/null) || tok=""
      if [ -z "$tok" ]; then
        warn "argocd: could not mint a token for account $ARGO_ACCOUNT (tools/kind-stack.sh $STACK up creates it) — continuing without argocd. It said:"
        tail -3 "$ERR_DIR/argo.err" | sed 's/^/    /' >&2; ARGO_TOKEN_ID=""
      elif ! is_jwt "$tok" || [ "$(jwt_sub "$tok")" != "$ARGO_ACCOUNT:apiKey" ]; then
        warn "argocd: minted token failed the shape/subject gate (sub='$(jwt_sub "$tok" 2>/dev/null)') — deleted, continuing without argocd"; argo_revoke keep || true
      else
        ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" > "$ERR_DIR/argo-jail.cfg" )
        can_i() { argo_api jail "$ARGO_URL/api/v1/account/can-i/$1" | jq -r '.value // "?"' 2>/dev/null || echo "?"; }
        bad=""
        # The whole RBAC ConfigMap first, from the host: its data must be exactly policy.csv as
        # tools/kind-stack.sh renders it plus an empty policy.default — no overlay key (Argo merges
        # every policy.*.csv), no matchMode or scopes — so a grant the probes below never ask about
        # (actions, exec, projects, other accounts) cannot hide in a line or a key they do not cover.
        _csv=$("$HERE/tools/kind-stack.sh" "$STACK" argo-policy 2>/dev/null) || _csv=""
        _want=$(jq -nS --arg csv "$_csv" '{"policy.csv": $csv, "policy.default": ""}')
        _have=$(kubectl --context "kind-$KIND_CLUSTER" -n argocd get cm argocd-rbac-cm -o json 2>/dev/null | jq -S '.data // {}') || _have="?"
        { [ -n "$_csv" ] && [ "$_have" = "$_want" ]; } || bad="$bad argocd-rbac-cm-is-not-what-kind-stack.sh-renders"
        unset _csv _want _have
        # The policy is glob-matched against the request object, so a grant on one app name
        # answers "no" to the wildcard probe: probe each name too, and the untouched default project.
        probes=("applications/create/$STACK/*" "applications/update/$STACK/*" "applications/delete/$STACK/*" "applications/override/$STACK/*" \
                "applications/update/default/*" "applications/create/default/*" "accounts/update/$ARGO_ACCOUNT" "accounts/update/admin" "accounts/update/*" "repositories/create/*" "projects/update/$STACK")
        for _app in $ARGO_APPS; do probes+=("applications/update/$STACK/$_app" "applications/delete/$STACK/$_app" "applications/override/$STACK/$_app"); done
        for q in "${probes[@]}"; do
          [ "$(can_i "$q")" = no ] || bad="$bad $q"
        done
        [ "$(can_i "applications/sync/$STACK/*")" = yes ] || bad="$bad no-sync"
        for _app in $ARGO_APPS; do [ "$(can_i "applications/sync/$STACK/$_app")" = yes ] || bad="$bad no-sync-$_app"; done
        rm -f "$ERR_DIR/argo-jail.cfg"
        if [ -n "$bad" ]; then
          warn "argocd: account $ARGO_ACCOUNT is not get+sync-only (tools/kind-stack.sh $STACK up resets its policy):$bad — token deleted, NOT installed"; argo_revoke keep || true
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
    fail "dev gate REFUSED: could not list $DEV_KUBE_SA permissions — dev credential NOT installed" >&2; sed 's/^/    /' "$ERR_DIR/dev-perms.err"; ok=0
  else
    bad=$(printf '%s\n' "$perms" | rules_not_readonly)
    [ -z "$bad" ] || { fail "dev gate REFUSED: $DEV_KUBE_SA is not read-only/secret-free; dev credential NOT installed:"; printf '%s\n' "$bad" | sed 's/^/    /' >&2; ok=0; }
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
STACK_ADDONS="${KIND_ADDONS:-}"; export STACK_ADDONS              # names only: which add-on card fragments the session gets (tools/jail-card.d/)
export STACK_DEVKUBE_NS="${DEV_KUBE_NS:-}" STACK_DEVKUBE_SA="${DEV_KUBE_SA:-}"   # the dev token itself never enters the jail


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
  record_add "$GITDIR_RECORD" notes/.git "$(gitdir_inode "$NOTES/.git")"   # the launcher made it, on the host
  GITDIR_RELS+=(notes/.git)
  ok "notes: created $NOTES (local git, no remote)"
fi
mkdir -p "$NOTES/uploads"
notes_snapshot "before session $(date +%F\ %T)"
VOLS+=(-v "$NOTES:/workspace/notes")

# Git internals read-only (each recorded gitdir: the repos' and notes'): config, hooks and
# commondir all decide what HOST git runs the next time it — or an IDE sharing the working tree —
# touches the repo (hooks, core.fsmonitor, core.sshCommand, filter drivers), and none shows up in a
# diff. commondir is the subtle one: a gitdir may contain a file redirecting where config is read
# from. A normal clone has none; "." means "this gitdir", which is the same thing — so the launcher
# writes "." on the host and mounts it read-only, and the jail can neither create nor change it.
# Costs: no repo-config writes in the jail (`push -u`, `remote add`, `branch --set-upstream-to`).
# Only RECORDED gitdirs (see Terms above) get here: an unrecorded one stopped the launch.
GITDIRS=(); GITDIR_IDS=()
for rel in ${GITDIR_RELS[@]+"${GITDIR_RELS[@]}"}; do
  d="$JAIL_HOME/$STACK/$rel"; cfg="$d/config"
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
done

# What mounts cannot cover, checked on the host at start and exit: a nested repository planted in
# a working tree, the build dir included (IDEs auto-detect those and run git in them, with THEIR
# config), a gitdir that is not recorded, the files git would only use for linked worktrees or
# per-worktree config, and a gitdir or config swapped for another one (inode + checksum, recorded
# at launch). Warn loudly; deleting is the human's call.
# Paths are printed quoted (%q): the jail picks the names, and an escape sequence in one would
# otherwise truncate or erase the warning on the host terminal.
mounted_gitdir() { local g; for g in ${GITDIR_RELS[@]+"${GITDIR_RELS[@]}"}; do [ "$g" = "$1" ] && return 0; done; return 1; }
audit_repos() { # <when>: "before session" is fatal on anything the mounts do not cover; "after session" warns
  local kind p x hits="" fatal="" i=0 d scan
  if scan=$(gitdir_scan); then                              # the same scan as the launch check
    while IFS=$'\t' read -r kind p x; do
      case "$kind" in
        gitdir) if ! record_has "$GITDIR_RECORD" "$p" "$x"; then hits="$hits"$'\n'"    gitdir not recorded, or replaced since (inspect, then --adopt): $(printf '%q' "$p")"; fatal=1
                elif ! mounted_gitdir "$p"; then hits="$hits"$'\n'"    gitdir recorded after this launch's scan (a stack-fork.sh run?), so its config and hooks would NOT be read-only: $(printf '%q' "$p")"; fatal=1; fi ;;
        refuse) hits="$hits"$'\n'"    $x: $(printf '%q' "$p")"; fatal=1 ;;
        nested) hits="$hits"$'\n'"    nested repo: $(printf '%q' "$p")" ;;
      esac
    done <<< "$scan"
  else
    hits="$hits"$'\n'"    THE SCAN DID NOT RUN — nested repos and unrecorded gitdirs were not checked; fix tools/gitdir-scan.sh and launch again before touching the tree"; fatal=1
  fi
  for d in ${GITDIRS[@]+"${GITDIRS[@]}"}; do                # bash 3.2 (macOS) + set -u: empty-array safe
    [ "$(cat "$d/commondir" 2>/dev/null)" = "." ] || hits="$hits"$'\n'"    commondir changed: $(printf '%q' "$d/commondir")"
    for x in rebase-merge rebase-apply sequencer; do          # a todo left there runs its `exec` lines on the host at `--continue`
      [ ! -e "$d/$x" ] || hits="$hits"$'\n'"    in-progress $x in $(printf '%q' "$d/") — inspect its todo before any --continue"
    done
    [ ! -e "$d/config.worktree" ] || hits="$hits"$'\n'"    per-worktree config: $(printf '%q' "$d/config.worktree")"
    [ ! -d "$d/worktrees" ] || hits="$hits"$'\n'"    linked worktrees: $(printf '%q' "$d/worktrees/") (yours?)"
    [ "$(gitdir_id "$d")" = "${GITDIR_IDS[$i]}" ] || hits="$hits"$'\n'"    gitdir or its config replaced: $(printf '%q' "$d")"
    i=$((i + 1))
  done
  [ -z "$hits" ] || warn "git audit ($1) — do NOT run git or open these in an IDE until inspected:$hits"
  if [ "$1" = "before session" ] && [ -n "$fatal" ]; then fail "FATAL: the tree changed between the scan and the mounts — launch again"; exit 2; fi
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
  docker rm -f "$DEVPROXY" "$GITPROXY" "$BUILDER" "$NETNS" "jail-$STACK" >/dev/null 2>&1 || true   # the jail is --rm, but a killed launcher leaves it
  rm -f "$RUN_DIR/dev-kubeconfig"
}
on_exit() { # every step guarded: errexit applies inside a trap, and a failed revoke must not skip the audit, the snapshot or the lock
  cleanup || true; argo_revoke || true; audit_repos "after session" || true; notes_snapshot "after session $(date +%F\ %T)" || true
  rm -rf "$ERR_DIR"; rmdir "$LOCK" 2>/dev/null || true
}
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
    # From each RECORDED gitdir's remotes as wired on the host by tools/stack-fork.sh, not from
    # directory names: a local-only dir has no fork (a .git the jail planted in one is unrecorded,
    # and stopped the launch above), and a same-named repo of another stack in the shared fork org
    # must not land on this stack's lists. The config file is parsed with no system or global
    # config; it is the one the launcher mounts read-only, so the jail never wrote it.
    remote_repo() { # <gitdir> <remote> → owner/repo, lowercase, if the URL is on github.com; else nothing
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$1/config" --get "remote.$2.url" 2>/dev/null \
        | sed -nE 's#^(https?://|git@|ssh://git@)github\.com[:/]##p' | sed -E 's#/+$##; s#\.git$##' | tr '[:upper:]' '[:lower:]' | grep -E '^[^/]+/[^/]+$' || true
    }
    _fork_org=$(printf '%s' "$FORK_ORG" | tr '[:upper:]' '[:lower:]'); _up_owner=$(printf '%s' "${UPSTREAM_OWNER:-}" | tr '[:upper:]' '[:lower:]')
    for r in $REPOS; do
      gd="$JAIL_HOME/$STACK/$r/.git"; record_line "$GITDIR_RECORD" "$r/.git" || continue  # a local-only dir: nothing to push to (an unrecorded gitdir stopped the launch)
      o=$(remote_repo "$gd" origin); u=$(remote_repo "$gd" upstream)
      case "$o" in
        "$_fork_org/"*) GITPROXY_WRITE="$GITPROXY_WRITE,github.com/$o" ;;
        "") if GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config --file "$gd/config" --get remote.origin.url >/dev/null 2>&1; then
              warn "git: $r's origin is not on github.com — not on the push list (tools/stack-fork.sh $STACK wires forks)"
            else info "git: $r has no origin — a local repo (a lab?), not on the push list"; fi ;;
        *) warn "git: $r's origin is $o, not a fork in $FORK_ORG — not on the push list (tools/stack-fork.sh $STACK)" ;;
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
  BUILD_HOST_DIR="$JAIL_HOME/$STACK/build"; mkdir -p "$BUILD_HOST_DIR"
  BUILD_WORK_DIR="$RUN_DIR/builder"; mkdir -p "$BUILD_WORK_DIR/workspace" "$BUILD_WORK_DIR/layers"   # pack's /workspace and /layers (builder.sh): host-only, the jail sees neither
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
      -v "$BUILD_HOST_DIR:/build" -v "$BUILD_WORK_DIR/workspace:/workspace" -v "$BUILD_WORK_DIR/layers:/layers" \
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
  case "$GH_PUBLIC_TOKEN" in github_pat_*) ;; *) fail "gh gate REFUSED: GH_PUBLIC_TOKEN is not a fine-grained token (github_pat_…) — NOT installed"; GH_PUBLIC_TOKEN=unverifiable ;; esac
  if [ "$GH_PUBLIC_TOKEN" != unverifiable ]; then
    # Any failure (network, non-JSON) leaves the variables empty / "?" and refuses: fail closed, not out.
    login=$(gh_api user | jq -r '.login // empty' 2>/dev/null) || login=""
    private=$(gh_api 'user/repos?visibility=private&per_page=1' | jq -r 'if type == "array" then length else "?" end' 2>/dev/null) || private="?"
    if [ -z "$login" ]; then
      fail "gh gate REFUSED: GH_PUBLIC_TOKEN is not valid or api.github.com is unreachable (GET /user failed) — NOT installed" >&2; sed 's/^/    /' "$ERR_DIR/gh-public.err"
    elif [ "$private" != 0 ]; then
      fail "gh gate REFUSED: GH_PUBLIC_TOKEN can see private repositories (or the probe failed: '$private') — NOT installed"
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
docker compose -f "$HERE/docker-compose.yml" run --rm --name "jail-$STACK" \
  "${VOLS[@]}" \
  -e STACK_NAME -e JAIL_NAME -e JAIL_READS -e STACK_REPOS -e STACK_READS -e UPLOAD_DIR -e UPLOAD_HOST_PORT \
  -e STACK_GITPROXY -e GITPROXY_WRITE -e GITLAB_HOST -e GITLAB_FORK_PATH -e FORK_ORG -e GH_TOKEN \
  -e STACK_KUBE_TOKEN -e STACK_KUBE_SERVER -e STACK_KUBE_CA -e STACK_KUBE_NS -e STACK_KUBE_SA \
  -e STACK_DEVKUBE_PROXY -e STACK_DEVKUBE_NS -e STACK_DEVKUBE_SA \
  -e STACK_BUILD_DIR -e STACK_BUILD_REGISTRY -e STACK_BUILD_NAMES -e STACK_ARGO_SERVER -e STACK_ARGO_TOKEN -e STACK_ADDONS \
  stack \
  bash -c "source /workspace/tools/stack-jail-init.sh && cd /workspace/$PRIMARY && exec claude ${JAIL_CLAUDE_FLAGS:-}"

}
main "$@"
