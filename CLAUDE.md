# claude-jail-work — per-client Claude Code jails under an employer-managed policy

Repo facts only. **Session ground rules do not live here** — they live in
[`tools/jail-card.md`](tools/jail-card.md), composed into `CLAUDE.local.md` at container start.
Derived from the home variant (`upstream`, fetch-only); cherry-pick in either direction deliberately.

## What this repo is

- `Dockerfile` + `docker-compose.yml`: one image, two services — `claude` (the **login/mechanism
  jail**: only this repo mounted; the one session that maps the OAuth port) and `client` (the
  **per-client jail**: scoped repo mounts, per-client tokens, two minted kubeconfig files;
  launcher `tools/client-jail.sh`, in-container init `tools/client-jail-init.sh`).
- `clients/<name>.conf`: what a client jail mounts — generic by rule (repo dir names, primary dir,
  kind cluster, a host port). Client FACTS never go here; they live in `~/claude/jail/.env.<name>`.
- `tools/kdev`: the read-only wrapper for the client dev cluster. `tools/upload/`: the file-drop
  server. `.aliases`: host launch shortcuts, loopback-only ports.

## Hard rules

- **Tokens + git are the boundaries; everything else is scenery.** No credential in a jail may be
  able to write to an upstream repo or mutate a client cluster. The launcher is the only place
  credentials are injected, and every credential it injects is scoped and short-lived.
- **Nothing client-derived in this repo** — no copied files, no retyped files, no facts (CIDRs,
  hostnames, SA names, GitLab URLs). Those live in the gitignored per-client env file.
- **Pushes are human** under the managed policy (`! git push` from the prompt, or from the host).
  The launcher passes no permission-bypass flag; `JAIL_CLAUDE_FLAGS` exists for a granted exception.
- **No OpenRouter / OpenCode / third-party model routing** in this variant — it is not permitted at
  work. Anthropic via the account login only.
