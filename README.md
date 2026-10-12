# claude-jail-work — Docker jails for Claude Code, one per stack

The work variant of [claude-jail](https://github.com/teststuffstash/claude-jail): Claude Code in a
container that holds only one stack's repositories (one client's project, e.g. SiVa) and a few scoped, short-lived credentials,
under whatever permission mode the account's managed policy allows.

**Design rule:** tokens + git are the boundaries. A jail's credentials cannot write to an upstream
repository or mutate a client cluster, so the container needs no command filter to be safe.
The generic security model — boundaries vs scenery, every measure and where it lives, accepted
risks, open items — is [docs/security.md](docs/security.md). Client-specific notes stay outside
this repo.

## Layout on the host

```
~/claude/claude-jail-work/          this repo (the mechanism)
~/claude/jail/<stack>/<repo>/       per-stack workspaces — each repo: `upstream` fetch-only, `origin` = your fork
~/claude/jail/<stack>/notes/        shared notes + upload inbox: local git, no remote, never published
~/claude/jail/.env.<stack>          tokens + client FACTS (outside any repo, mode 600; tools/stack-env.sh)
~/claude/jail/.claude-data*         Claude state: shared login + per-stack memory/history
~/claude/jail/.run-<stack>/         sidecar request logs (git proxy, dev proxy), one each per session
```

## Bootstrap

Host prerequisites: Docker with the compose plugin, devbox, and `gh` logged in (for
`stack-fork.sh`). The host-side scripts take `kubectl`, `kind` and `gh` from this repo's
`devbox.json` (exact pins, via `tools/host-tools.sh`), not from whatever the host has installed.
The same file pins the host's interactive tools for these stacks, `k9s` and the `argocd` CLI (the
3.4 line is what nixpkgs has; it tolerates the 3.5 server with a warning), so the whole team runs
one version set and nothing is installed globally: `devbox shell` here, or
`devbox run -- k9s --context kind-siva`. Never a stack repo's devbox on the host: that file is
jail-written, and its init_hook would run as you.

Once per machine:

```bash
./setup-env.sh                  # .env (UID/GID, JAIL_HOME), state files, jail gitconfig template
docker compose build
tools/pin-aliases.sh            # review + pin .aliases, then add the ~/.zshrc snippet from the
                                # script header and open a new shell
jail-main                       # the login jail: /login once (it maps the OAuth port on loopback)
```

Fill in `~/claude/jail/.claude-data.gitconfig` (the jail's git identity) while you are at it.

Checks, on the host or in `jail-main`: `devbox run ci` runs shellcheck over every script,
hadolint over both Dockerfiles (`.hadolint.yaml` lists the one ignored rule and why), gitleaks over the whole git history and the working tree (the "nothing client-derived, no
credential in git" rule as a check; `.gitleaks.toml` holds the few allowed paths),
`tools/review_md.py` (generates the gitignored `REVIEW.md` from the security model's Review
column, which also validates that every measure row has one), `ruff check` (including bandit's rule set, `S`) + `ruff format --check`
over the Python, and the end-to-end tests in `tests/`
(each server started against a fake peer and driven through real requests; the build sidecar's
loop against a fake lifecycle and helm; `kind-stack.sh`'s registry policy rendering). `devbox run lint` and
`devbox run test` are the halves. The tools are pinned in `devbox.json` next to the host tools.

Per stack (`siva` as the example):

```bash
tools/stack-env.sh siva         # creates ~/claude/jail/.env.siva (mode 600) — fill it in
tools/stack-fork.sh siva        # fork into FORK_ORG, clone from UPSTREAM_OWNER, wire remotes
tools/kind-stack.sh siva up     # the stack's kind cluster + registry + namespace/SA the launcher mints for
siva                            # the stack jail (alias for tools/stack-jail.sh siva)
devbox install                  # inside the jail, once: each stack has its own Nix store
```

A stack needs a `stacks/<name>.conf` (see `stacks/siva.conf`) and an alias line in `.aliases`
(then `jail-pin`). `stack-fork.sh` is idempotent: re-run it after adding a repo to `REPOS` —
remotes can't be changed inside a jail. `kind-stack.sh` is the whole host side of a stack's kind
cluster: the per-stack registry (Zot: anyone pulls, one generated credential pushes, and only the
names in `BUILD_NAMES`; its web UI is on the loopback port), the cluster, containerd's registry config, and the namespace
(with `pod-security.kubernetes.io/enforce: baseline`, which the launcher requires before minting),
the workbench ServiceAccount and its RoleBinding — and, when the conf lists `ARGO_APPS`, Argo CD:
the pinned upstream release, a repository entry for the stack registry's charts (OCI, plain HTTP),
an AppProject confined to the stack namespace, one auto-syncing Application per chart name, the
jail's get+sync account, and a read Role so `kubectl -n argocd get app` works from the jail — all
from the conf, so every stack gets the same shape. `kind-stack.sh <stack> ui` forwards the Argo CD
UI to host loopback (a port-forward, so it works on Linux, Mac and Windows alike) and prints the
admin login. **The host runs nothing from a stack's tree**: a lab repo is jail-written, so cluster
lifecycle and anything else you execute on the host belongs in `tools/`. Identities, by design:

| Purpose | Credential | Reach |
|---|---|---|
| GitHub forks | fine-grained PAT, resource owner = your trust-domain org, Contents R/W + Metadata only (git needs nothing else, the sidecar exposes nothing else); held by the git proxy sidecar, never by the jail | pushes to this stack's forks only (the sidecar's allowlist), fetches anywhere on github.com |
| GitHub API (`gh`), optional | fine-grained PAT, resource owner = you, public repositories only, no permissions; the one token that enters the jail, gated at launch (fine-grained, valid, sees no private repo). Only for stacks whose upstreams and forks are all public | authenticated rate limit for `gh` reads; every write refused by GitHub |
| Client GitLab, read | personal token, `read_repository`; held by the sidecar | fetch upstream |
| Client GitLab, write | deploy token, `write_repository`, on YOUR fork inside the client's GitLab, protected `main`; held by the sidecar | that fork's unprotected branches |
| Local kind | namespace-admin ServiceAccount, minted per launch, 8 h | one namespace, plain `kubectl` |
| Argo CD on kind, optional (`ARGO_APPS` in the conf) | token for a local Argo account whose whole policy is get, sync and logs on the stack's project; minted per launch, 8 h, deleted at session end, after the API confirms as that token that it cannot write Applications, repos, the project or the account | `argocd app get/sync/wait/logs` on this stack's Applications |
| Kind registry push | user/password for the stack's registry (Zot, anonymous pull); generated by `kind-stack.sh` into `.env.<stack>` when absent; held by the build sidecar (`tools/builder/`), never by the jail | the sidecar's own pushes: image, cache and chart under `BUILD_NAMES`, which the registry's policy enforces too |
| Client dev cluster | read-only ServiceAccount, minted per launch after impersonation proves it cannot mutate or read secrets, 8 h; held by a proxy sidecar, never by the jail | GET through the proxy (`kdev`) |

## What the launcher does (`tools/stack-jail.sh`)

1. Reads `stacks/<stack>.conf` and `~/claude/jail/.env.<stack>`; refuses to continue without the
   shared login file or the primary repo. Pins the status line and a `permissions.allow` list
   (default: everything per tool; comma-separated `JAIL_ALLOW` in the conf overrides) into the stack's own Claude
   settings, so the jail runs without prompts for what the managed policy does not deny.
2. Mints the kind token (only if the namespace enforces Pod Security `baseline`/`restricted` and the
   SA can't undo that), the Argo CD token if the stack has Argo CD (only if the API, asked as that
   token, denies every write and allows sync; deleted again at exit) and, if configured, the dev
   token (only if the SA's full permission list is read-only and secret-free) — each checked for
   JWT shape and the expected `sub` claim.
3. Mounts only the stack's repo dirs, its `notes/` and the per-stack Claude state, with each repo's
   `.git/config`, `.git/hooks` and `.git/commondir` read-only. Snapshots `notes/` (local git) and
   audits the repos for planted nested repositories before the session and again after it.
4. Starts the jail's network namespace like a Kubernetes pod: a pause container on a per-stack
   bridge (+ the kind network) that publishes the upload UI on a loopback port, plus the sidecars
   in that namespace: the git proxy (`tools/gitproxy/`), which holds the GitHub and GitLab tokens,
   forwards git smart-HTTP only and accepts pushes only for this stack's forks, on
   `127.0.0.1:8002`, reached as `www.github.com:8002` / `www.<gitlab>:8002` through the
   namespace's hosts file (so `gh` still resolves the repo from the remotes); and, if dev is
   configured, a `kubectl proxy` that holds the dev token and
   serves read-only on `127.0.0.1:8001`; and, if the conf names a `BUILDER_IMAGE`, the build
   sidecar (`tools/builder/`: that Paketo builder plus helm, image `jail-<stack>-builder`) that
   runs the CNB lifecycle on requests from the shared `~/claude/jail/<stack>/build` dir and pushes
   image and chart to the kind registry, `BUILD_NAMES` only, holding the registry credential the
   jail never gets (jail side: `tools/build-image`). Then it starts `claude` in that namespace with no git
   token, no dev token and no bypass flag, and removes the sidecars (saving their request logs)
   when the session ends.
   `tools/stack-jail-init.sh` routes git to the sidecar (`url.insteadOf`, no credential store),
   writes `~/.kube/kind.yaml` and a credential-less `~/.kube/dev.yaml`, and renders the session
   card.

## Not in this variant

Passwordless sudo, the Docker socket, host kubeconfig or SSH keys, cross-jail handoff channels,
and any OpenRouter / OpenCode routing. The image is built on the host (`docker compose build`);
pushes are the human's.
