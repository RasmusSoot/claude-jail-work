#!/usr/bin/env python3
"""gitproxy — the git credential sidecar. Stdlib only.

Runs in the jail's network namespace and listens on its loopback. The jail's git talks plain HTTP to
    http://www.<host>:8002/<owner>/<repo>.git/...
where www.<host> resolves to 127.0.0.1 inside the namespace (an /etc/hosts entry on the pause
container), and this proxy forwards to https://<host>/<owner>/<repo>.git/... with the credential
for that host and path. The upstream is chosen by the Host header, from a fixed list. The "www."
name is what makes `gh` work in a repo directory: `git remote -v` shows insteadOf-rewritten URLs,
and gh normalises www.github.com to github.com but would treat 127.0.0.1 as an unknown host.
No git token is ever inside the jail; the jail's ~/.gitconfig routes every URL shape of each host
here with url.<base>.insteadOf (tools/stack-jail-init.sh).

Policy, enforced for ANY client in the namespace (git, curl, a repo's own scripts):
  - hosts: github.com always (anonymously when there is no token), GITLAB_HOST if set; others 404
  - only git smart-HTTP endpoints:
        GET  <repo>/info/refs?service=git-upload-pack | git-receive-pack
        POST <repo>/git-upload-pack | <repo>/git-receive-pack
    nothing else is forwarded, so neither host's REST API (nor git-lfs) is reachable with the tokens
  - receive-pack (push) only for repos on the write allowlist (GITPROXY_WRITE); the rest is 403
  - the GitHub token is sent only for repos on the read or write allowlist (this stack's upstreams
    and forks); every other github.com repo is fetched anonymously, so an org-wide token cannot
    read another stack's private fork from here
  - a client-supplied Authorization header is dropped; an upstream 401 is answered as 403 so git
    fails instead of prompting for a credential nothing here could supply
One line per request on stdout: method, host, repo, service, decision, upstream status, bytes.
Never a token, never a query string beyond the service name.

Env:
  GITPROXY_LISTEN       host:port, default 127.0.0.1:8002
  GITPROXY_WRITE        comma-separated "<host>/<path>" repos that may receive pushes
  GITPROXY_READ         comma-separated "<host>/<path>" github.com repos fetched WITH the token
  GH_TOKEN              github.com credential (Basic x-access-token:<token>)
  GITLAB_HOST           client GitLab host
  GITLAB_READ_TOKEN     GitLab credential for every path (Basic oauth2:<token>)
  GITLAB_FORK_PATH, GITLAB_DEPLOY_USER, GITLAB_DEPLOY_TOKEN
                        GitLab credential for the fork path only (Basic <user>:<token>)
  GITPROXY_UPSTREAM_SCHEME  "https" (default); "http" only for tests against a local fake upstream
"""

from __future__ import annotations

import base64
import http.client
import os
import re
import ssl
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("GITPROXY_LISTEN", "127.0.0.1:8002")
SCHEME = os.environ.get("GITPROXY_UPSTREAM_SCHEME", "https")
GH_TOKEN = os.environ.get("GH_TOKEN", "")
GITLAB_HOST = os.environ.get("GITLAB_HOST", "").lower()
GITLAB_READ_TOKEN = os.environ.get("GITLAB_READ_TOKEN", "")
GITLAB_FORK_PATH = os.environ.get("GITLAB_FORK_PATH", "")
GITLAB_DEPLOY_USER = os.environ.get("GITLAB_DEPLOY_USER", "") or "gitlab+deploy-token"
GITLAB_DEPLOY_TOKEN = os.environ.get("GITLAB_DEPLOY_TOKEN", "")

ROUTE = re.compile(r"^/(.+?)/(info/refs|git-upload-pack|git-receive-pack)$")
SERVICES = {"git-upload-pack", "git-receive-pack"}
# Hop-by-hop and proxy-owned request headers: never forwarded as received.
DROP_REQ = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "authorization",
    "expect",
    "content-length",
}
# Hop-by-hop response headers, plus the ones send_response() emits itself.
DROP_RESP = {"connection", "keep-alive", "transfer-encoding", "content-length", "server", "date"}
CHUNK = 64 * 1024
TLS = ssl.create_default_context()


def norm(path: str) -> str:
    """Repo path as compared: lowercase, no trailing slash, no .git."""
    path = path.strip("/").lower()
    return path[:-4] if path.endswith(".git") else path


def hostname(addr: str) -> str:
    """'Host:port' -> 'host', lowercase, without a 'www.' prefix."""
    h = addr.rpartition(":")[0] if ":" in addr and not addr.endswith("]") else addr
    h = h.lower()
    return h[4:] if h.startswith("www.") else h


def listing(var: str) -> set[str]:
    out = set()
    for e in os.environ.get(var, "").split(","):
        if e.strip():
            h, _, p = e.strip().partition("/")
            out.add(f"{hostname(h)}/{norm(p)}")
    return out


# Served hostname (what the jail's Host header names, minus www.) -> upstream address (may carry a port).
UPSTREAMS = {hostname(h): h for h in ("github.com", GITLAB_HOST) if h}
GITLAB = hostname(GITLAB_HOST) if GITLAB_HOST else ""
WRITE = listing("GITPROXY_WRITE")
READ = listing("GITPROXY_READ") | WRITE


def credential(host: str, repo: str) -> tuple[str, str] | None:
    if host == "github.com":
        return ("x-access-token", GH_TOKEN) if GH_TOKEN and f"{host}/{norm(repo)}" in READ else None
    if host == GITLAB:
        if GITLAB_DEPLOY_TOKEN and GITLAB_FORK_PATH and norm(repo) == norm(GITLAB_FORK_PATH):
            return GITLAB_DEPLOY_USER, GITLAB_DEPLOY_TOKEN
        if GITLAB_READ_TOKEN:
            return "oauth2", GITLAB_READ_TOKEN
    return None


def log(*fields: object) -> None:
    print(time.strftime("%Y-%m-%dT%H:%M:%S"), *fields, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "gitproxy"
    sys_version = ""

    def log_message(self, *_: object) -> None:  # the default logs the full request line; ours is explicit
        pass

    # ── request body as an iterator: Content-Length or chunked (git uses both) ──────────────────
    def body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size <= 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):  # trailers
                        pass
                    return
                left = size
                while left:
                    data = self.rfile.read(min(CHUNK, left))
                    if not data:
                        return
                    left -= len(data)
                    yield data
                self.rfile.readline()  # CRLF after the chunk
        else:
            left = int(self.headers.get("Content-Length") or 0)
            while left > 0:
                data = self.rfile.read(min(CHUNK, left))
                if not data:
                    return
                left -= len(data)
                yield data

    def refuse(self, code: int, text: str, *fields: object) -> None:
        body = (text + "\n").encode()
        self.close_connection = True  # an unread POST body may follow
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        log(self.command, *fields, "->", code, text)

    def do_GET(self) -> None:
        self.handle_git("GET")

    def do_POST(self) -> None:
        self.handle_git("POST")

    def handle_git(self, method: str) -> None:
        url = urllib.parse.urlsplit(self.path)
        host = hostname(self.headers.get("Host", ""))
        m = ROUTE.match(url.path)
        if not m:
            return self.refuse(404, "not a git smart-HTTP endpoint", host, url.path)
        repo, endpoint = m.group(1), m.group(2)
        if host not in UPSTREAMS:
            return self.refuse(404, "host not served here", host, repo)
        upstream = UPSTREAMS[host]
        if endpoint == "info/refs":
            if method != "GET":
                return self.refuse(405, "info/refs is GET", host, repo)
            service = urllib.parse.parse_qs(url.query).get("service", [""])[0]
            if service not in SERVICES:
                return self.refuse(403, "only smart-HTTP services are proxied", host, repo, service or "-")
            target = f"/{repo}/info/refs?service={service}"
        else:
            if method != "POST":
                return self.refuse(405, f"{endpoint} is POST", host, repo)
            service, target = endpoint, f"/{repo}/{endpoint}"
        if service == "git-receive-pack" and f"{host}/{norm(repo)}" not in WRITE:
            return self.refuse(403, "push refused: not a fork this jail may write to", host, repo, service)

        headers = {k: v for k, v in self.headers.items() if k.lower() not in DROP_REQ}
        cred = credential(host, repo)
        if cred:
            headers["Authorization"] = "Basic " + base64.b64encode(f"{cred[0]}:{cred[1]}".encode()).decode()
        length = self.headers.get("Content-Length")
        chunked_in = "chunked" in self.headers.get("Transfer-Encoding", "").lower()
        if method == "POST" and length is not None and not chunked_in:
            headers["Content-Length"] = length

        started = time.monotonic()
        conn = None
        try:
            if SCHEME == "https":
                conn = http.client.HTTPSConnection(upstream, timeout=600, context=TLS)
            else:
                conn = http.client.HTTPConnection(upstream, timeout=600)
            if method == "POST":
                conn.request("POST", target, body=self.body(), headers=headers, encode_chunked="Content-Length" not in headers)
            else:
                conn.request("GET", target, headers=headers)
            resp = conn.getresponse()
        except (OSError, ValueError, http.client.HTTPException) as e:
            if conn:
                conn.close()
            return self.refuse(502, f"upstream request failed: {e.__class__.__name__}", host, repo, service)

        try:
            if resp.status == 401:
                resp.read()
                return self.refuse(403, "upstream refused the proxy's credential", host, repo, service, "upstream=401")
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() == "location" and v.startswith(f"{SCHEME}://{upstream}/"):
                    v = f"http://{self.headers.get('Host', LISTEN)}/" + v[len(f"{SCHEME}://{upstream}/") :]
                if k.lower() not in DROP_RESP:
                    self.send_header(k, v)
            length = resp.getheader("Content-Length")
            bodyless = resp.status in (204, 304) or 100 <= resp.status < 200
            chunked = length is None and not bodyless
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            elif not bodyless:
                self.send_header("Content-Length", length)
            self.end_headers()
            sent = 0
            while not bodyless:
                data = resp.read(CHUNK)
                if not data:
                    break
                sent += len(data)
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data) if chunked else data)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
            if length is not None and not bodyless and sent != int(length):
                self.close_connection = True  # upstream cut the body short: don't leave the client waiting
                log(method, host, repo, service, "-> truncated", f"{sent}/{length}B")
            else:
                log(method, host, repo, service, "->", resp.status, f"{sent}B", f"{time.monotonic() - started:.1f}s")
        except (OSError, http.client.HTTPException) as e:
            self.close_connection = True
            log(method, host, repo, service, "-> aborted", e.__class__.__name__)
        finally:
            conn.close()


def main() -> int:
    host, _, port = LISTEN.rpartition(":")
    if not GH_TOKEN and not GITLAB_HOST:
        print("gitproxy: no GH_TOKEN and no GITLAB_HOST — nothing to serve", file=sys.stderr)
        return 2
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    log(
        f"gitproxy: serving {LISTEN} as www.<host> for {' '.join(sorted(UPSTREAMS))}; github.com token for: {' '.join(sorted(READ)) or '<none>'};"
        f" push allowed to: {' '.join(sorted(WRITE)) or '<none>'}"
    )
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
