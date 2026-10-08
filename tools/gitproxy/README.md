# gitproxy — the git credential sidecar

Stdlib-only Python reverse proxy for git smart HTTP. It is to the GitHub and GitLab tokens what the
`kubectl proxy` sidecar is to the dev cluster token: the token lives in a sidecar container in the
jail's network namespace, the jail talks plain HTTP to it on loopback, and the sidecar adds the
credential and enforces policy for every client, whether that is `git`, `curl` or a repo's own
build script.

## Run

Started by `tools/stack-jail.sh` as the `gitproxy` compose service (`jail-<stack>-gitproxy`) when
the stack's env file has `GH_TOKEN` or `GITLAB_HOST`. It serves on `127.0.0.1:8002` of the jail's
namespace, and the jail addresses it as `http://www.<host>:8002/<owner>/<repo>.git`: the launcher
adds `www.github.com` and `www.<GITLAB_HOST>` → `127.0.0.1` to the namespace holder's `/etc/hosts`,
which every container in the namespace shares, and the proxy picks the upstream from the Host
header (a fixed list, nothing else is served). `tools/stack-jail-init.sh` rewrites every URL shape
of `github.com` and the client GitLab (`https://`, `http://`, `https://www.`, `git@host:`,
`ssh://git@host/`) to that form with `url.<base>.insteadOf` in the jail's own `~/.gitconfig`. Repo
configs are untouched, so the host keeps its own remotes, keys and helpers.

Why `www.`: `git remote -v` shows insteadOf-rewritten URLs, and `gh` resolves the repository from
them. It treats `127.0.0.1` as an unknown host and refuses every in-repo command, but it strips a
`www.` prefix and treats `www.github.com` as `github.com` (verified with gh 2.98; `api.github.com`
and `*.github.com` subdomains are *not* accepted). Nothing else on a system ever talks to
`www.github.com`, so taking that name over inside the namespace costs nothing. The request log is
saved to `~/claude/jail/.run-<stack>/gitproxy-<time>.log` at session end.

## Policy

- Hosts: `github.com` always (anonymously when there is no `GH_TOKEN`, so public clones keep
  working on a GitLab-only stack) and `GITLAB_HOST`. Anything else is 404.
- Endpoints: `GET <repo>/info/refs?service=…`, `POST <repo>/git-upload-pack`,
  `POST <repo>/git-receive-pack`. Nothing else is forwarded, so neither host's REST API is reachable
  with the tokens: no `gh`, no `glab`, no issue or PR calls. Git LFS (`info/lfs/…`) is not forwarded
  either; an LFS repo does not work in a jail.
- Pushes (`git-receive-pack`, including its ref advertisement) only for repos in `GITPROXY_WRITE`:
  `FORK_ORG/<repo>` for each repo of the stack on GitHub, and `GITLAB_FORK_PATH` on GitLab. Compared
  case-insensitively, with or without `.git`.
- The GitHub token is sent only for repos in `GITPROXY_READ` (`UPSTREAM_OWNER/<repo>`) or
  `GITPROXY_WRITE`; every other github.com repo is fetched anonymously. An org-wide token therefore
  cannot read another stack's private fork from this jail. On GitLab the deploy token is used for
  the fork path and the read token elsewhere (the launcher knows no GitLab upstream path to narrow
  it to). A client-supplied `Authorization` header is dropped.
- An upstream 401 is answered as 403, so git fails instead of prompting (`GIT_TERMINAL_PROMPT=0` is
  set in the jail as well). A refusal closes the connection; a truncated upstream body closes it too
  instead of leaving git waiting.
- One log line per request: method, host, repo, service, decision, upstream status, bytes, time.
  Never a token, never a query string beyond the service name.
- Not rewritten in the jail, so not proxied: `ssh://host:PORT/` with a non-default SSH port and
  `https://user@host/`. They fail or run anonymously; no token is involved either way.

## Tests

`devbox run test` (or `python3 -m unittest discover -s tests`): `tests/test_gitproxy.py` starts the
proxy against a fake upstream in the test process and checks the forwarded path and credential per
host and repo, chunked request bodies, redirect rewriting, the push and host refusals, the 401→403
mapping, connection handling and that the log holds no token.

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
