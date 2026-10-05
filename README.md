# claude-jail-work — Docker jails for Claude Code, one per client

The work variant of [claude-jail](https://github.com/teststuffstash/claude-jail): Claude Code in a
container that holds only one client's repositories and a few scoped, short-lived credentials,
under whatever permission mode the account's managed policy allows.

**Design rule:** tokens + git are the boundaries. A jail's credentials cannot write to an upstream
repository or mutate a client cluster, so the container needs no command filter to be safe.
The reasoning and the credential inventory are kept with the jail design notes (outside this repo
until they are client-free enough to publish).

## Layout on the host

```
~/claude/claude-jail-work/          this repo (the mechanism)
~/claude/jail/<client>/<repo>/      per-client workspaces — each repo: `upstream` fetch-only, `origin` = your fork
~/claude/jail/.env.<client>         tokens + client FACTS (gitignored, chmod 600; created on first launch)
~/claude/jail/.claude-data*         Claude state: shared login + per-client memory/history
```

## Bootstrap

```bash
./setup-env.sh            # writes .env (UID/GID, JAIL_HOME), pre-creates state files, generates the zsh override
docker compose build
source .aliases           # or add to ~/.zshrc
jail-main                 # the login jail: run /login here once (it maps the OAuth port on loopback)
siva                      # a client jail: tools/client-jail.sh siva
```

Per client you need: a `clients/<name>.conf` (see `clients/siva.conf`), the repos cloned under
`~/claude/jail/<name>/`, and the env file filled in. Identities, by design:

| Purpose | Credential | Reach |
|---|---|---|
| GitHub forks | fine-grained PAT, resource owner = your trust-domain org, Contents R/W + Metadata, no Pull requests | the org's forks only |
| Client GitLab, read | personal token, `read_repository` | fetch upstream |
| Client GitLab, write | deploy token, `write_repository`, on YOUR fork inside the client's GitLab, protected `main` | that fork's unprotected branches |
| Local kind | namespace-admin ServiceAccount, minted per launch, 8 h | one namespace, plain `kubectl` |
| Client dev cluster | read-only ServiceAccount, minted per launch after impersonation proves it cannot mutate or read secrets, 8 h | `kdev` only |

## What the launcher does (`tools/client-jail.sh`)

1. Reads `clients/<client>.conf` and `~/claude/jail/.env.<client>`; refuses to continue without the shared login file.
2. Mints the kind token and, if configured, the dev token — each checked for JWT shape and for the
   expected `sub` claim before it is injected; the dev ServiceAccount is checked by impersonation first.
3. Mounts only the client's repo dirs, the per-client Claude state and the shared credentials file.
4. Joins the client's kind Docker network, publishes the upload UI on a loopback port, and starts
   `claude` with no bypass flag. `tools/client-jail-init.sh` then builds the per-host git credential
   store, writes `~/.kube/kind.yaml` and `~/.kube/dev.yaml`, and renders the session card.

## Not in this variant

Passwordless sudo, the Docker socket, host kubeconfig or SSH keys, cross-jail handoff channels,
and any OpenRouter / OpenCode routing. Image builds and pushes happen in CI or by the human.
