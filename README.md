# claude-jail-work — Docker jails for Claude Code, one per stack

The work variant of [claude-jail](https://github.com/teststuffstash/claude-jail): Claude Code in a
container that holds only one stack's repositories (one client's project, e.g. SiVa) and a few
scoped, short-lived credentials, under whatever permission mode the account's managed policy
allows.

**Design rule:** tokens + git are the boundaries. A jail's credentials cannot write to an upstream
repository or mutate a client cluster, so the container needs no command filter to be safe.
The generic security model — boundaries vs scenery, every measure and where it lives, accepted
risks, open items — is [docs/security.md](docs/security.md) for the stack jail and
[docs/security-jail-main.md](docs/security-jail-main.md) for the login jail. Client-specific notes
stay outside this repo.

## Layout on the host

```
~/claude/claude-jail-work/          this repo (the mechanism)
~/claude/jail/<stack>/<repo>/       per-stack workspaces — each repo: `upstream` fetch-only, `origin` = your fork
~/claude/jail/<stack>/notes/        shared notes + upload inbox: local git, no remote, never published
~/claude/jail/.env.<stack>          tokens + client FACTS (outside any repo, mode 600; tools/stack-env.sh)
~/claude/jail/.claude-data*         Claude state: shared login + per-stack memory/history
~/claude/jail/.run-<stack>/         sidecar request logs (git proxy, dev proxy), one each per session
```

## Quickstart

From an empty machine to a running jail for one of the predefined stacks (`stacks/`: `siva`,
`siga`, `tara`, `govsso`, `ai-governance`), `siva` as the example. [Bootstrap](#bootstrap) and
[Identities](#identities) have the detail behind each step. It is written to be worked through
with Claude Code on the host (point it at this file); the steps that touch GitHub are yours.

1. **An org for the forks.** Create a GitHub organization you own (the free plan is enough), with
   fine-grained tokens allowed in its settings. It is the trust domain: the forks live there, the
   git token is scoped to it, so it holds nothing else. Its name is `FORK_ORG`.
2. **The git token** (GitHub → Settings → Developer settings → Fine-grained tokens): resource
   owner = that org, All repositories, permissions Contents read/write and Metadata read, nothing
   else. It never enters the jail: the git proxy sidecar holds it. This is `GH_TOKEN`.
3. **The `gh` token, optional**: a second fine-grained token, resource owner = you, Public
   repositories only, no permissions. It is the one token that enters the jail, so the launcher
   refuses anything broader. This is `GH_PUBLIC_TOKEN`; without it `gh` does not run in the jail.
4. **This repo on the host.** Docker with the compose plugin, devbox and `gh auth login` first.
   ```bash
   git clone <this repo> ~/claude/claude-jail-work && cd ~/claude/claude-jail-work
   ./setup-env.sh                  # .env, ~/claude/jail/ and the state files
   docker compose build
   tools/pin-aliases.sh            # then add the ~/.zshrc snippet from its header; open a new shell
   ```
5. **Log in once**: `jail-main`, then `/login` inside it. Every stack jail reuses that login.
   Fill in `~/claude/jail/.claude-data.gitconfig` (the jail's commit identity).
6. **The stack's env file**: `tools/stack-env.sh siva` creates `~/claude/jail/.env.siva`. Fill in
   `GH_TOKEN`, `FORK_ORG`, `UPSTREAM_OWNER` (the GitHub owner of the repos in the conf's `REPOS`)
   and, if you made one, `GH_PUBLIC_TOKEN`. The GitLab and dev-cluster lines stay empty until the
   stack has them; the registry credential is generated in the next step.
7. **The stack home**: `mkdir -p ~/claude/jail/siva/siva-lab`. It is the conf's `PRIMARY`, a
   local-only directory that is not forked (the fork script passes over it and the launcher
   refuses to start without it); its `CLAUDE.md` is what the session reads first.
8. **Fork, cluster, launch**:
   ```bash
   tools/stack-fork.sh siva        # forks into FORK_ORG, clones, wires the remotes
   tools/kind-stack.sh siva up     # kind cluster, registry, namespace, SA; Argo CD if the conf has ARGO_APPS
   siva                            # the jail; inside it, once: devbox install
   ```

A stack of your own needs a `stacks/<name>.conf` (copy one) and an alias line in `.aliases`,
then `jail-pin`; the steps are the same.

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

Checks, on the host or in `jail-main`: `devbox run ci` (`devbox run lint` and `devbox run test`
are its halves; the tools are pinned in `devbox.json` next to the host tools). It runs:

- shellcheck over every script, and hadolint over both Dockerfiles (`.hadolint.yaml` lists the one
  ignored rule and why);
- gitleaks over the whole git history and the working tree — the "nothing client-derived, no
  credential in git" rule as a check (`.gitleaks.toml` holds the few allowed paths);
- `tools/review_md.py`, which generates the gitignored `REVIEW.md` from the security model's
  Review column and so checks that every measure row has one;
- `ruff check` (including bandit's rule set, `S`) and `ruff format --check` over the Python;
- the end-to-end tests in `tests/`: each server started against a fake peer and driven through
  real requests, the build sidecar's loop against a fake lifecycle and helm, and `kind-stack.sh`'s
  registry policy rendering.

Per stack (`siva` as the example):

```bash
tools/stack-env.sh siva         # creates ~/claude/jail/.env.siva (mode 600) — fill it in
tools/stack-fork.sh siva        # fork into FORK_ORG, clone from UPSTREAM_OWNER, wire remotes, record the gitdirs
tools/kind-stack.sh siva up     # the stack's kind cluster + registry + namespace/SA the launcher mints for
siva                            # the stack jail (alias for tools/stack-jail.sh siva)
siva --second                   # a second Claude in the running siva jail: reads, plans, writes notes/ only
devbox install                  # inside the jail, once: each stack has its own Nix store
```

A stack needs a `stacks/<name>.conf` (see `stacks/siva.conf`) and an alias line in `.aliases`
(then `jail-pin`); the predefined ones in `stacks/` have both. The conf's `PRIMARY` is a local-only
stack home that the fork script does not create: `mkdir` it before the first launch.

One launch per stack at a time. To plan the next feature while the session builds the current one,
`<stack> --second` starts a second Claude in the running jail with `docker exec`. It has no lock, no
gates and no new credentials or mounts, and it stops when the first session exits. Its rules come
from `tools/second-jail.md`: read the repos and clusters, write only under `notes/` (plans in
`notes/plans/`), no git writes and no pushes; the primary session picks the notes up.

`stack-fork.sh` is idempotent: re-run it after adding a repo to `REPOS`, since remotes cannot be
changed inside a jail. It also records each clone it makes in `~/claude/jail/.run-<stack>/gitdirs`
(path and inode). The launcher trusts only recorded gitdirs and stops on any other `.git` it
finds, printing the exact `tools/stack-jail.sh <stack> --adopt <dir>/.git …` to run once you have
looked at it (one you made on the host with `git init`, or one a session planted). Submodules,
`.git` pointer files and symlinked gitdirs are refused outright.

`kind-stack.sh` is the whole host side of a stack's kind cluster, all from the conf, so every
stack gets the same shape:

- the per-stack registry (Zot: anyone pulls; one generated credential pushes, and only the names
  in `BUILD_NAMES`; its web UI is on the loopback port);
- the cluster (node image pinned by `KIND_NODE_IMAGE`) and containerd's registry config on its
  nodes;
- the namespace with `pod-security.kubernetes.io/enforce: baseline`, which the launcher requires
  before minting, plus the workbench ServiceAccount and its RoleBinding;
- when the conf lists `ARGO_APPS`, Argo CD: the pinned upstream release, a repository entry for
  the stack registry's charts (OCI, plain HTTP), an AppProject confined to the stack namespace,
  one auto-syncing Application per chart name, the jail's get+sync account, and a read Role so
  `kubectl -n argocd get app` works from the jail;
- when the conf also lists `KIND_ADDONS`, the cluster add-ons the jail cannot install (CRDs,
  ClusterRoles: first of them kube-prometheus-stack), one Application per file in `addons/`, in an
  Argo project `platform` limited to those files' public chart repos and namespaces; the jail sees
  them and cannot sync them ([`addons/README.md`](addons/README.md)).

`kind-stack.sh <stack> ui` forwards the Argo CD UI to host loopback (a port-forward, so it works
on Linux, Mac and Windows alike) and prints the admin login; `kind-stack.sh <stack> grafana` does
the same for Grafana when kube-prometheus-stack is among the add-ons. **The host runs nothing from a
stack's tree**: a lab repo is jail-written, so cluster lifecycle and anything else you execute on
the host belongs in `tools/`.

## Identities

By design:

| Purpose | Credential | Reach |
|---|---|---|
| GitHub forks | fine-grained PAT, resource owner = your trust-domain org, Contents R/W + Metadata only (git needs nothing else, the sidecar exposes nothing else); held by the git proxy sidecar, never by the jail | pushes to this stack's forks only (the sidecar's allowlist), fetches anywhere on github.com |
| GitHub API (`gh`), optional | fine-grained PAT, resource owner = you, public repositories only, no permissions; the one token that enters the jail, gated at launch (fine-grained, valid, sees no private repo). Only for stacks whose upstreams and forks are all public | authenticated rate limit for `gh` reads; every write refused by GitHub |
| Client GitLab, read | personal token, `read_repository`; held by the sidecar | fetch upstream |
| Client GitLab, write | deploy token, `write_repository`, on YOUR fork inside the client's GitLab, protected `main`; held by the sidecar | that fork's unprotected branches |
| Local kind | namespace-admin ServiceAccount, minted per launch, 8 h | one namespace, plain `kubectl` |
| Argo CD on kind, optional (`ARGO_APPS` in the conf) | token for a local Argo account whose whole policy is get, sync and logs on the stack's project; minted per launch, 8 h, after the API confirms as that token that it cannot write Applications, repos, the project or other accounts; the account is disabled between sessions and every token on it deleted at launch and at session end; the admin login that does this verifies Argo's TLS certificate | `argocd app get/sync/wait/logs` on this stack's Applications |
| Kind registry push | user/password for the stack's registry (Zot, anonymous pull); generated by `kind-stack.sh` into `.env.<stack>` when absent; held by the build sidecar (`tools/builder/`), never by the jail | the sidecar's own pushes: image, cache and chart under `BUILD_NAMES`, which the registry's policy enforces too |
| Client dev cluster | read-only ServiceAccount, minted per launch after impersonation proves it cannot mutate or read secrets, 8 h; held by a proxy sidecar, never by the jail | GET through the proxy (`kdev`) |

## What the launcher does (`tools/stack-jail.sh`)

1. Reads `stacks/<stack>.conf` and `~/claude/jail/.env.<stack>`; refuses to continue without the
   shared login file or the primary repo. Pins the status line and a `permissions.allow` list
   (default: everything per tool; comma-separated `JAIL_ALLOW` in the conf overrides) into the
   stack's own Claude
   settings, so the jail runs without prompts for what the managed policy does not deny.
2. Mints the kind token (only if the namespace enforces Pod Security `baseline`/`restricted` and the
   SA can't undo that), the Argo CD token if the stack has Argo CD (only if the API, asked as that
   token, denies every write and allows sync; deleted again at exit) and, if configured, the dev
   token (only if the SA's full permission list is read-only and secret-free) — each checked for
   JWT shape and the expected `sub` claim.
3. Mounts only the stack's repo dirs, its `notes/` and the per-stack Claude state, with each
   recorded gitdir's `config`, `hooks` and `commondir` read-only. Snapshots `notes/` (local git)
   and audits the repos for planted nested repositories and unrecorded gitdirs before the session
   and again after it.
4. Starts the jail's network namespace like a Kubernetes pod: a pause container on a per-stack
   bridge (plus the kind network) that publishes the upload UI on a loopback port, and in that
   namespace the sidecars:
   - the git proxy (`tools/gitproxy/`), which holds the GitHub and GitLab tokens, forwards git
     smart-HTTP only and accepts pushes only for this stack's forks, on `127.0.0.1:8002`, reached
     as `www.github.com:8002` / `www.<gitlab>:8002` through the namespace's hosts file (so `gh`
     still resolves the repo from the remotes);
   - if dev is configured, a `kubectl proxy` that holds the dev token and serves read-only on
     `127.0.0.1:8001`;
   - if the conf names a `BUILDER_IMAGE`, the build sidecar (`tools/builder/`: that Paketo
     builder plus helm, image `jail-<stack>-builder`), which runs the CNB lifecycle on requests
     from the shared `~/claude/jail/<stack>/build` dir and pushes image and chart to the kind
     registry, `BUILD_NAMES` only, holding the registry credential the jail never gets (jail
     side: `tools/build-image`).

   Then it starts `claude` in that namespace with no git token, no dev token and no bypass flag,
   and removes the sidecars (saving their request logs) when the session ends.
   `tools/stack-jail-init.sh` routes git to the sidecar (`url.insteadOf`, no credential store),
   writes `~/.kube/kind.yaml` and a credential-less `~/.kube/dev.yaml`, and renders the session
   card.

## Not in this variant

Passwordless sudo, the Docker socket, host kubeconfig or SSH keys, cross-jail handoff channels,
and any OpenRouter / OpenCode routing. The image is built on the host (`docker compose build`);
pushes are the human's.
