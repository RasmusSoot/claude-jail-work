# claude-jail-work — per-stack Claude Code jails under an employer-managed policy

Repo facts only. **Session ground rules do not live here** — they live in
[`tools/jail-card.md`](tools/jail-card.md), composed into `CLAUDE.local.md` at container start.
Derived from the home variant (`upstream`, fetch-only); cherry-pick in either direction deliberately.

## What this repo is

- `Dockerfile` + `docker-compose.yml`: one image, two services — `claude` (the **login/mechanism
  jail**: only this repo mounted; the one session that maps the OAuth port) and `stack` (the
  **per-stack jail**: scoped repo mounts + `notes/`, per-stack tokens, a kind kubeconfig and a
  credential-less dev kubeconfig served by a proxy sidecar; launcher `tools/stack-jail.sh`,
  in-container init `tools/stack-jail-init.sh`).
- `stacks/<name>.conf`: what a stack jail mounts — generic by rule (repo dir names, primary dir,
  kind cluster, a host port). Client FACTS never go here; they live in `~/claude/jail/.env.<name>`.
- Host-side scripts: `tools/stack-env.sh` (env file template), `tools/stack-fork.sh` (fork, clone,
  remotes), `tools/kind-stack.sh` (a stack's kind cluster, registry with push policy, Argo CD),
  `tools/pin-aliases.sh` (`jail-pin`). Those that call `kubectl`/`kind`/`gh` take them from this
  repo's `devbox.json` via `tools/host-tools.sh`. `.aliases`: host launch shortcuts, loopback-only
  ports. `tools/review_md.py` generates `REVIEW.md`.
- In-jail: `tools/kdev` (the dev cluster wrapper), `tools/build-image` (hands a jar to the build
  sidecar), `tools/statusline.sh`, `tools/upload/` (the file-drop server).
- Sidecars the launcher starts next to a stack jail: `tools/gitproxy/` (git credentials),
  `tools/builder/` (the Paketo build + push), a `kubectl proxy` for the dev cluster.
- `docs/security.md`: the security model — what is a boundary, what is scenery, what is accepted.
  Every measure row carries a Review sentence: the rule a reviewer holds a diff to. `REVIEW.md`
  is generated from those by `tools/review_md.py` (lint runs it, so the doc's structure is checked;
  the file is gitignored and never edited by hand). Reviewing a change here means reading that
  column, or the generated file.

## Hard rules

- **Tokens + git are the boundaries; everything else is scenery.** No credential in a jail may be
  able to write to an upstream repo or mutate a client cluster. The launcher is the only place
  credentials are injected, and every credential it injects is scoped and short-lived.
- **Nothing client-derived in this repo** — no copied files, no retyped files, no facts (CIDRs,
  hostnames, SA names, GitLab URLs). Those live in the gitignored per-stack env file.
- **Pushes are human** under the managed policy (`! git push` from the prompt, or from the host).
  The launcher passes no permission-bypass flag; `JAIL_CLAUDE_FLAGS` exists for a granted exception.
- **No OpenRouter / OpenCode / third-party model routing** in this variant — it is not permitted at
  work. Anthropic via the account login only.
