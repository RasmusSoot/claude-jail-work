# stack-jail-init — sourced (bash) inside a per-stack jail before exec'ing claude.
# Consumes the env tools/stack-jail.sh injects. Everything here is container-local session state
# (credential store, kubeconfig files, session card); nothing persists but ~/.claude.
# Sourced, not executed: exports into the claude process. Always returns 0.

_sj_warn() { echo "stack-jail-init: $*" >&2; }

# ── git identity + per-host credential routing ──────────────────────────────────────────────────
[ -f /home/node/.gitconfig-base ] && cp /home/node/.gitconfig-base "$HOME/.gitconfig" || _sj_warn "no .gitconfig-base — set user.name/email"
git config --global credential.helper "store --file $HOME/.git-credentials"
git config --global remote.pushDefault origin        # triangular: track upstream, push to the fork
git config --global push.default current
: > "$HOME/.git-credentials"; chmod 600 "$HOME/.git-credentials"
# github.com: ONE entry — the fork-org token. Its reach is set by GitHub (the org's repos), not by path;
# it also authenticates reads of public upstreams (rate limits), and cannot write outside the org.
[ -n "${GH_TOKEN:-}" ] && printf 'https://x-access-token:%s@github.com\n' "$GH_TOKEN" >> "$HOME/.git-credentials" \
  || _sj_warn "GH_TOKEN empty — GitHub pushes/gh will not work"
# GitLab: path-specific deploy token FIRST (store returns the first match), host-wide read token after.
if [ -n "${GITLAB_HOST:-}" ]; then
  git config --global "credential.https://$GITLAB_HOST.useHttpPath" true
  if [ -n "${GITLAB_DEPLOY_TOKEN:-}" ] && [ -n "${GITLAB_FORK_PATH:-}" ]; then
    printf 'https://%s:%s@%s/%s\nhttps://%s:%s@%s/%s.git\n' \
      "${GITLAB_DEPLOY_USER:-gitlab+deploy-token}" "$GITLAB_DEPLOY_TOKEN" "$GITLAB_HOST" "$GITLAB_FORK_PATH" \
      "${GITLAB_DEPLOY_USER:-gitlab+deploy-token}" "$GITLAB_DEPLOY_TOKEN" "$GITLAB_HOST" "$GITLAB_FORK_PATH" >> "$HOME/.git-credentials"
  fi
  [ -n "${GITLAB_READ_TOKEN:-}" ] && printf 'https://oauth2:%s@%s\n' "$GITLAB_READ_TOKEN" "$GITLAB_HOST" >> "$HOME/.git-credentials"
fi

# ── kubectl: two FILES, never two contexts in one ───────────────────────────────────────────────
mkdir -p "$HOME/.kube"
_sj_kubeconfig() { # <file> <context> <server> <ca> <token> <ns> <user>
  cat > "$1" <<EOT
apiVersion: v1
kind: Config
clusters: [{ name: $2, cluster: { server: "$3", certificate-authority-data: "$4" } }]
users:    [{ name: $7, user: { token: "$5" } }]
contexts: [{ name: $2, context: { cluster: $2, user: $7, namespace: "$6" } }]
current-context: $2
EOT
  chmod 600 "$1"
}
if [ -n "${STACK_KUBE_TOKEN:-}" ]; then
  _sj_kubeconfig "$HOME/.kube/kind.yaml" kind-local "$STACK_KUBE_SERVER" "$STACK_KUBE_CA" "$STACK_KUBE_TOKEN" "$STACK_KUBE_NS" "$STACK_KUBE_SA"
  export KUBECONFIG="$HOME/.kube/kind.yaml"            # plain `kubectl` = the local kind cluster
  _sj_kind="namespace-admin SA \`$STACK_KUBE_SA\` in \`$STACK_KUBE_NS\` on the local kind cluster (8h token). Destructive verbs are fine here — it is disposable."
else
  _sj_kind="no kind token this session — plain \`kubectl\` is unavailable."
fi
if [ -n "${STACK_DEVKUBE_TOKEN:-}" ]; then
  _sj_kubeconfig "$HOME/.kube/dev.yaml" client-dev "$STACK_DEVKUBE_SERVER" "$STACK_DEVKUBE_CA" "$STACK_DEVKUBE_TOKEN" "$STACK_DEVKUBE_NS" "$STACK_DEVKUBE_SA"
  _sj_dev="READ-ONLY SA \`$STACK_DEVKUBE_SA\` in \`$STACK_DEVKUBE_NS\` (8h, verified non-mutating, no secrets). ONLY via \`kdev <verb> ...\` — never set KUBECONFIG to it."
else
  _sj_dev="no dev credential this session — \`kdev\` is unavailable."
fi
export PATH="/workspace/tools:$PATH"                   # kdev

# ── session card ────────────────────────────────────────────────────────────────────────────────
{
  cat <<EOT
# ${STACK_NAME:-stack} jail — session card
<!-- rendered at session start by tools/stack-jail-init.sh from the injected env — edit the renderer (or tools/jail-card.md below), not this file -->

- **Stack: ${STACK_NAME:-?}.** Mounted repos under \`/workspace\`: ${STACK_REPOS:-<none>}. Nothing else of the host is visible.
- **Read-only views**: $(if [ -n "${STACK_READS:-}" ]; then echo "$(printf '%s' "${STACK_READS}" | tr ' ' '\n' | sed 's|\(.*\):\(.*\)|/reads/\1/\2|' | paste -sd, -) — other stacks' working trees as they are on the host, uncommitted edits included. Read, compare, cite; never try to write, build in, or push from them — their remotes and tokens are not in this jail."; else echo "none this session."; fi)
- **git**: \`upstream\` is fetch-only; \`origin\` is YOUR fork and the only place any token here can write. GitHub token present: $([ -n "${GH_TOKEN:-}" ] && echo yes || echo no). GitLab deploy token present: $([ -n "${GITLAB_DEPLOY_TOKEN:-}" ] && echo yes || echo no). Pushes are the human's (\`! git push\`); add a Co-Authored-By trailer to commits you author.
- **kubectl (kind)**: ${_sj_kind}
- **kdev (client dev)**: ${_sj_dev}
- **uploads**: files dropped via the upload UI land in \`${UPLOAD_DIR:-/workspace/uploads}\` (gitignored inbox).

---
EOT
  if [ -f /workspace/tools/jail-card.md ]; then cat /workspace/tools/jail-card.md; else _sj_warn "tools/jail-card.md missing"; echo "(ground-rules card missing)"; fi
} > /workspace/CLAUDE.local.md 2>/dev/null || _sj_warn "could not write /workspace/CLAUDE.local.md"

unset _sj_kind _sj_dev GITLAB_DEPLOY_TOKEN GITLAB_READ_TOKEN
unset STACK_KUBE_TOKEN STACK_KUBE_CA STACK_DEVKUBE_TOKEN STACK_DEVKUBE_CA
unset -f _sj_warn _sj_kubeconfig 2>/dev/null
true
