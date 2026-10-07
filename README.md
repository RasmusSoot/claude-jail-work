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
~/claude/jail/.env.<stack>         tokens + client FACTS (gitignored, chmod 600; created on first launch)
~/claude/jail/.claude-data*         Claude state: shared login + per-stack memory/history
```

## Bootstrap

```bash
./setup-env.sh            # writes .env (UID/GID, JAIL_HOME), pre-creates state files
docker compose build
tools/pin-aliases.sh     # review + pin .aliases; ~/.zshrc sources the pinned copy (snippet in the script header)
jail-main                 # the login jail: run /login here once (it maps the OAuth port on loopback)
siva                      # a stack jail: tools/stack-jail.sh siva
```

Per stack you need: a `stacks/<name>.conf` (see `stacks/siva.conf`), the repos cloned under
`~/claude/jail/<name>/`, and the env file filled in. Identities, by design:

| Purpose | Credential | Reach |
|---|---|---|
| GitHub forks | fine-grained PAT, resource owner = your trust-domain org, Contents R/W + Metadata, no Pull requests | the org's forks only |
| Client GitLab, read | personal token, `read_repository` | fetch upstream |
| Client GitLab, write | deploy token, `write_repository`, on YOUR fork inside the client's GitLab, protected `main` | that fork's unprotected branches |
| Local kind | namespace-admin ServiceAccount, minted per launch, 8 h | one namespace, plain `kubectl` |
| Client dev cluster | read-only ServiceAccount, minted per launch after impersonation proves it cannot mutate or read secrets, 8 h | `kdev` only |

## What the launcher does (`tools/stack-jail.sh`)

1. Reads `stacks/<stack>.conf` and `~/claude/jail/.env.<stack>`; refuses to continue without the shared login file.
2. Mints the kind token and, if configured, the dev token — each checked for JWT shape and for the
   expected `sub` claim before it is injected; the dev ServiceAccount is checked by impersonation first.
3. Mounts only the client's repo dirs, the per-stack Claude state and the shared credentials file.
4. Starts the jail's network namespace like a Kubernetes pod: a pause container on a per-stack
   bridge (+ the kind network) that publishes the upload UI on a loopback port, and, if dev is
   configured, a `kubectl proxy` sidecar in the same namespace that holds the dev token and serves
   read-only on `127.0.0.1:8001`. Then it starts `claude` in that namespace with no bypass flag, and
   removes the sidecars (saving the proxy's request log) when the session ends.
   `tools/stack-jail-init.sh` builds the per-host git credential store, writes `~/.kube/kind.yaml`
   and a credential-less `~/.kube/dev.yaml`, and renders the session card.

## Not in this variant

Passwordless sudo, the Docker socket, host kubeconfig or SSH keys, cross-jail handoff channels,
and any OpenRouter / OpenCode routing. Image builds and pushes happen in CI or by the human.
