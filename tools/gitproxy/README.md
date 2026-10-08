# gitproxy — the git credential sidecar

Stdlib-only Python reverse proxy for git smart HTTP. It is to the GitHub and GitLab tokens what the
`kubectl proxy` sidecar is to the dev cluster token: the token lives in a sidecar container in the
jail's network namespace, the jail talks plain HTTP to it on loopback, and the sidecar adds the
credential and enforces policy for every client, whether that is `git`, `curl` or a repo's own
build script.

## Run

Started by `tools/stack-jail.sh` as the `gitproxy` compose service (`jail-<stack>-gitproxy`) when
the stack's env file has `GH_TOKEN` or `GITLAB_HOST`. It serves on `127.0.0.1:8002` of the jail's
namespace. `tools/stack-jail-init.sh` then rewrites every URL shape of `github.com` and the client
GitLab (`https://`, `http://`, `git@host:`, `ssh://git@host/`) to it with `url.<base>.insteadOf` in
the jail's own `~/.gitconfig`. Repo configs are untouched, so the host keeps its own remotes, keys
and helpers. Its request log is saved to `~/claude/jail/.run-<stack>/gitproxy-<time>.log` at
session end.

## Policy

- Hosts: `github.com` (with `GH_TOKEN`) and `GITLAB_HOST`. Anything else is 404.
- Endpoints: `GET <repo>/info/refs?service=…`, `POST <repo>/git-upload-pack`,
  `POST <repo>/git-receive-pack`. Nothing else is forwarded, so neither host's REST API is reachable
  with the tokens: no `gh`, no `glab`, no issue or PR calls.
- Pushes (`git-receive-pack`, including its ref advertisement) only for repos in `GITPROXY_WRITE`:
  `FORK_ORG/<repo>` for each repo of the stack on GitHub, and `GITLAB_FORK_PATH` on GitLab. Compared
  case-insensitively, with or without `.git`.
- Credentials: `x-access-token:$GH_TOKEN` for GitHub; on GitLab the deploy token for the fork path,
  the read token elsewhere. A client-supplied `Authorization` header is dropped.
- An upstream 401 is answered as 403, so git fails instead of prompting (`GIT_TERMINAL_PROMPT=0` is
  set in the jail as well).
- One log line per request: method, host, repo, service, decision, upstream status, bytes, time.
  Never a token, never a query string beyond the service name.

## Test by hand

Inside any jail (or on the host), against GitHub with no credential:

```bash
GITLAB_HOST=github.com GITPROXY_LISTEN=127.0.0.1:18002 GITPROXY_WRITE=github.com/octocat/Hello-World \
  python3 tools/gitproxy/gitproxy.py &
git clone http://127.0.0.1:18002/github.com/octocat/Hello-World.git           # 200s in the log
git -C Hello-World push http://127.0.0.1:18002/github.com/octocat/Spoon-Knife.git HEAD:x   # 403: not on the allowlist
git -C Hello-World push http://127.0.0.1:18002/github.com/octocat/Hello-World.git HEAD:x   # 403: upstream 401, no credential
```

## Why stdlib

Same reason as the upload server: no pip, non-root, and `http.server` plus `http.client` is all a
smart-HTTP forwarder needs (chunked request bodies, `Expect: 100-continue` and streamed responses
included).
