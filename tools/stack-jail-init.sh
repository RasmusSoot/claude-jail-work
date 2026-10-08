# shellcheck shell=bash
# stack-jail-init — sourced (bash) inside a per-stack jail before exec'ing claude.
# Consumes the env tools/stack-jail.sh injects. Everything here is container-local session state
# (git routing, kubeconfig files, session card); nothing persists but ~/.claude.
# Sourced, not executed: exports into the claude process. Always returns 0.

_sj_warn() { echo "stack-jail-init: $*" >&2; }

# ── git identity + routing through the credential sidecar ───────────────────────────────────────
# No token and no credential helper in here. Every URL shape of github.com and the client GitLab
# (https, http, scp-style ssh, ssh://) is rewritten to http://www.<host>:<port>/, which is the
# gitproxy sidecar: www.<host> resolves to the namespace's loopback (/etc/hosts of the namespace
# holder), and the sidecar adds the credential and enforces the push allowlist. Repo configs stay
# as the host wrote them (and are read-only), so the host keeps its own remotes, keys and helpers.
# `git remote -v` shows the REWRITTEN URL (insteadOf applies there); `git config --get
# remote.origin.url` shows the configured one. The "www." form is what keeps `gh` working in a repo
# directory: it normalises www.github.com to github.com, while 127.0.0.1 is an unknown host to it.
if [ -f /home/claude/.gitconfig-base ]; then cp /home/claude/.gitconfig-base "$HOME/.gitconfig"; else _sj_warn "no .gitconfig-base — set user.name/email"; fi
git config --global remote.pushDefault origin        # triangular: track upstream, push to the fork
git config --global push.default current
if [ -n "${STACK_GITPROXY:-}" ]; then
  _sj_route() { # <host>: every URL shape of <host> -> http://www.<host>:<port>/
    local h="${1%%:*}" u
    for u in "https://$1/" "http://$1/" "https://www.$h/" "git@$1:" "ssh://git@$1/"; do
      git config --global --add "url.http://www.$h:$STACK_GITPROXY/.insteadOf" "$u"
    done
    getent hosts "www.$h" 2>/dev/null | grep -q '^127\.0\.0\.1 ' || _sj_warn "www.$h does not resolve to loopback — git to $1 will NOT reach the sidecar"
  }
  _sj_route github.com
  [ -n "${GITLAB_HOST:-}" ] && _sj_route "$GITLAB_HOST"
  export GIT_TERMINAL_PROMPT=0                       # a refused request fails; nothing here could answer a prompt
  _sj_git="GitHub${GITLAB_HOST:+ and GitLab} traffic goes through a credential sidecar (no git token in this jail; git smart-HTTP only, so no API access): remotes show as \`http://www.<host>:$STACK_GITPROXY/…\`, which is that sidecar. Pushes are accepted ONLY to: ${GITPROXY_WRITE:-<none>}."
else
  _sj_git="no credential sidecar this session — public fetches only, every push fails."
fi
if [ -n "${GH_TOKEN:-}" ]; then
  _sj_gh="\`gh\` is authenticated with a public-read-only token (fine-grained, public repositories, no permissions: it only buys the rate limit) and works in a repo directory without \`-R\`. Reads work; EVERY write (pr create/merge/comment, issues, releases) is refused by GitHub — those are the human's, from the host."
else
  _sj_gh="\`gh\` has no token here and refuses to run without one. Pull requests and issues are the human's, from the host."
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
if [ -n "${STACK_DEVKUBE_PROXY:-}" ]; then
  # No credential: the dev proxy sidecar (same network namespace, loopback only) holds the token,
  # and refuses writes, secrets, exec/attach/portforward and proxying for any client.
  cat > "$HOME/.kube/dev.yaml" <<EOT
apiVersion: v1
kind: Config
clusters: [{ name: client-dev, cluster: { server: "$STACK_DEVKUBE_PROXY" } }]
users:    [{ name: via-proxy, user: {} }]
contexts: [{ name: client-dev, context: { cluster: client-dev, user: via-proxy, namespace: "$STACK_DEVKUBE_NS" } }]
current-context: client-dev
EOT
  _sj_dev="READ-ONLY SA \`$STACK_DEVKUBE_SA\` in \`$STACK_DEVKUBE_NS\` through a proxy that holds the token (8h; GET only, no secrets, no exec). Use \`kdev <verb> ...\`."
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
- **git**: \`upstream\` is fetch-only; \`origin\` is YOUR fork. ${_sj_git} Pushes are the human's (\`! git push\`); add a Co-Authored-By trailer to commits you author.
- **gh**: ${_sj_gh}
- **kubectl (kind)**: ${_sj_kind}
- **kdev (client dev)**: ${_sj_dev}
- **notes**: \`/workspace/notes\` — the human's and agents' shared, persistent notes for this stack. Never committed to any repo or published; client facts are fine here. A local git repo with no remote: the launcher snapshots it before and after each session, so whatever you write is reviewed. Read it at the start of non-trivial work; write things meant to outlast this session.
- **uploads**: files dropped via the upload UI land in \`${UPLOAD_DIR:-/workspace/notes/uploads}\` (gitignored inbox, outside every repo).

---
EOT
  if [ -f /workspace/tools/jail-card.md ]; then cat /workspace/tools/jail-card.md; else _sj_warn "tools/jail-card.md missing"; echo "(ground-rules card missing)"; fi
} > /workspace/CLAUDE.local.md 2>/dev/null || _sj_warn "could not write /workspace/CLAUDE.local.md"

unset _sj_kind _sj_dev _sj_git _sj_gh                 # GH_TOKEN stays: it is gh's, public-read-only, gated by the launcher
unset STACK_KUBE_TOKEN STACK_KUBE_CA
unset -f _sj_warn _sj_kubeconfig _sj_route 2>/dev/null
true
