# Jail card — container ground rules for every jail session

<!-- The ONE versioned home for jail-session ground rules. Composed into the session at container
start — never hand-pasted, never edited at the composition target (edit THIS file):
  - login jail: tools/jail-entrypoint.sh writes it to /workspace/CLAUDE.local.md;
  - stack jail: tools/stack-jail-init.sh prepends its rendered per-stack card and writes the
    pair to /workspace/CLAUDE.local.md (container-local). -->

You are running inside a Docker container that holds only this stack's repositories and a small
set of scoped credentials. The permission mode is whatever the account's policy allows; do not try
to change it, and do not build wrappers around commands the policy denies — a denied push means the
human pushes.

## The boundaries (tokens + git — everything else is scenery)

- **git**: `upstream` remotes are fetch-only. `origin` is the human's fork and the only place any
  token here can write. Code reaches upstream only through a merge or pull request the human opens
  under their own name. Add a `Co-Authored-By` trailer to
  commits you author. In stack jails each repo's `.git/config`, `.git/hooks` and `.git/commondir` are read-only, so
  `push -u`, `remote add` and `branch --set-upstream-to` fail by design — push without `-u`.
- **kubectl**: plain `kubectl` is the LOCAL KIND cluster (namespace-admin, disposable — destructive
  verbs are fine there). `kdev` is the CLIENT DEV cluster, read-only through a proxy that holds the
  token (no credential is in this jail): anything but GET, and any secrets, exec, attach,
  port-forward or proxy request, gets 403. `kdev auth can-i` does not work (it is a POST). Never set
  `KUBECONFIG` by hand, never `use-context`, never merge the two files. Every `kdev` call prints its cluster banner — read it.
- **No client fact in any repo**: CIDRs, hostnames, ServiceAccount names, the GitLab URL — these
  live in the human's gitignored env file. Charts and configs you write come from public sources
  or from the client's own repo, never retyped into a third place.
- **Secrets**: if a command output contains a token, key or personal data, say so generically and
  do not echo it. `kdev` cannot read secrets on purpose; do not look for another way.

## Environment

- Container base: `debian:trixie` with only the jail's own needs (git, python3, jq, curl, procps);
  runs as `claude` with the host UID/GID; no sudo. No node, kubectl or gh in the image — use the
  repo's devbox (`devbox run …`).
- **Project tooling is Devbox/Nix, not apt.** `/nix` is a jail-only store (one Docker volume per
  stack, never the host's), so `devbox install` / `devbox run` work here directly; the same
  committed `devbox.json` works on the host against the host's own store.
- Memory and session history persist at `/home/claude/.claude` (bind-mounted per stack).
- A stack may declare `READS`: other stacks' repo dirs mounted read-only under `/reads/<stack>/<repo>`.
  They are views, not workspaces — no tokens for them, no commits in them.
- Published ports are loopback-only on the host. The upload server (inbox: `notes/uploads/` in a
  stack jail) needs the per-session token printed at launch — never echo or log that URL.

## Behavior

- Prefer fixing things directly over explaining how to fix them. Be concise.
- **Prior-art check before creating anything named** (a doc, script, chart, manifest): grep the
  repo first and say what you found before writing. Extend what exists; never create a parallel one.
- **Resolve references before acting on them.** When the human names a thing, it exists — find it.
- **Two clusters means every claim names its cluster.** "Works" is not a finding; "works on kind,
  dev shows X" is.
