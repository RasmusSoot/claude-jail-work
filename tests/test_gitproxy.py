"""gitproxy end-to-end: start the sidecar against a fake upstream, run requests through it, check
what the upstream received and what the client got back. Stdlib only (`python3 -m unittest`)."""

from __future__ import annotations

import http.client
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROXY = Path(__file__).resolve().parents[1] / "tools" / "gitproxy" / "gitproxy.py"
READ_TOKEN, DEPLOY_TOKEN = "read-secret-TOKEN", "deploy-secret-TOKEN"
ADVERT = b"001e# service=git-upload-pack\n0000"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port: int, timeout: float = 5.0) -> None:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"nothing listening on {port}")


class Upstream(BaseHTTPRequestHandler):
    """Fake GitLab/GitHub: records every request; HTTP/1.0, so POST replies have no Content-Length
    (that exercises the proxy's chunked response path) while GET replies set one (passthrough)."""

    seen: list[dict] = []

    def log_message(self, *_):
        pass

    def _record(self) -> bytes:
        if "chunked" in self.headers.get("Transfer-Encoding", ""):  # the proxy re-chunks streamed bodies
            body = b""
            while (size := int(self.rfile.readline().strip() or b"0", 16)) > 0:
                body += self.rfile.read(size)
                self.rfile.readline()
            self.rfile.readline()
        else:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
        self.seen.append({"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body})
        return body

    def do_GET(self):
        self._record()
        if "needs-auth" in self.path:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="x"')
            self.end_headers()
            return
        if self.path.startswith("/moved/"):
            self.send_response(301)
            self.send_header("Location", f"http://{self.headers['Host']}/new/repo.git/info/refs?service=git-upload-pack")
            self.end_headers()
            return
        if self.path.startswith("/truncate/"):  # promises 100 bytes, sends 10, closes
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b"0123456789")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-git-upload-pack-advertisement")
        self.send_header("Content-Length", str(len(ADVERT)))
        self.end_headers()
        self.wfile.write(ADVERT)

    def do_POST(self):
        body = self._record()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-git-upload-pack-result")
        self.end_headers()
        self.wfile.write(b"echo:" + body)


class GitProxyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        cls.up_host = f"127.0.0.1:{cls.upstream.server_port}"
        threading.Thread(target=cls.upstream.serve_forever, daemon=True).start()
        cls.port = free_port()
        cls.log = tempfile.NamedTemporaryFile("w+", prefix="gitproxy-", suffix=".log", delete=False)
        env = {
            "PATH": os.environ["PATH"],
            "GITPROXY_UPSTREAM_SCHEME": "http",
            "GITPROXY_LISTEN": f"127.0.0.1:{cls.port}",
            "GITLAB_HOST": cls.up_host,
            "GITLAB_READ_TOKEN": READ_TOKEN,
            "GITLAB_FORK_PATH": "me/fork",
            "GITLAB_DEPLOY_USER": "deployer",
            "GITLAB_DEPLOY_TOKEN": DEPLOY_TOKEN,
            "GITPROXY_WRITE": f"{cls.up_host}/me/fork",
        }
        cls.proc = subprocess.Popen([sys.executable, "-I", str(PROXY)], env=env, stdout=cls.log, stderr=subprocess.STDOUT)
        wait_port(cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(5)
        cls.upstream.shutdown()
        cls.log.seek(0)
        log = cls.log.read()
        cls.log.close()
        os.unlink(cls.log.name)
        # One line per request, never a token, never a query string.
        assert READ_TOKEN not in log and DEPLOY_TOKEN not in log, "token leaked into the proxy log"
        assert "service=" not in log, "query string leaked into the proxy log"
        assert "git-receive-pack" in log and "push refused" in log

    def setUp(self):
        Upstream.seen.clear()

    def request(self, method: str, path: str, body=None, headers=None, host=None, **kw):
        """A request as the jail's git would send it: to loopback, with Host: www.<upstream host>:<port>.
        `path` may be '/<host>/<repo>...' to pick another Host, as in the real jail's URL shape."""
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        default_host = f"www.{self.up_host.partition(':')[0]}:{self.port}"
        hdrs = {"Host": default_host if host is None else host, **(headers or {})}
        conn.request(method, path, body=body, headers=hdrs, **kw)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp, data

    def auth(self, i: int = 0) -> str:
        return Upstream.seen[i]["headers"].get("Authorization", "")

    # ── transformation ───────────────────────────────────────────────────────────────────────
    def test_fetch_is_forwarded_with_the_read_token(self):
        resp, data = self.request("GET", "/group/upstream.git/info/refs?service=git-upload-pack")
        self.assertEqual(resp.status, 200)
        self.assertEqual(data, ADVERT)
        self.assertEqual(resp.getheader("Content-Type"), "application/x-git-upload-pack-advertisement")
        self.assertEqual(len(Upstream.seen), 1)
        self.assertEqual(Upstream.seen[0]["path"], "/group/upstream.git/info/refs?service=git-upload-pack")
        self.assertEqual(self.auth(), "Basic b2F1dGgyOnJlYWQtc2VjcmV0LVRPS0VO")  # oauth2:read-secret-TOKEN

    def test_push_to_the_fork_uses_the_deploy_token(self):
        resp, data = self.request("POST", "/ME/Fork.GIT/git-receive-pack", body=b"pack-bytes")
        self.assertEqual(resp.status, 200)
        self.assertEqual(data, b"echo:pack-bytes")
        self.assertEqual(Upstream.seen[0]["path"], "/ME/Fork.GIT/git-receive-pack")
        self.assertEqual(self.auth(), "Basic ZGVwbG95ZXI6ZGVwbG95LXNlY3JldC1UT0tFTg==")  # deployer:deploy-secret-TOKEN

    def test_client_authorization_is_replaced_not_forwarded(self):
        self.request("GET", "/x/y.git/info/refs?service=git-upload-pack", headers={"Authorization": "Basic ZXZpbDpldmls"})
        self.assertNotIn("ZXZpbDpldmls", self.auth())
        self.assertTrue(self.auth().startswith("Basic "))

    def test_chunked_request_body_arrives_intact(self):
        parts = [b"0032want ", b"a" * 40, b"\n", b"0000", b"0009done\n"]
        resp, data = self.request(
            "POST",
            "/x/y.git/git-upload-pack",
            body=iter(parts),
            encode_chunked=True,
            headers={"Content-Type": "application/x-git-upload-pack-request"},
        )
        self.assertEqual(resp.status, 200)
        self.assertEqual(data, b"echo:" + b"".join(parts))
        self.assertEqual(Upstream.seen[0]["body"], b"".join(parts))
        self.assertEqual(Upstream.seen[0]["headers"].get("Content-Type"), "application/x-git-upload-pack-request")

    def test_redirect_location_points_back_at_the_proxy(self):
        resp, _ = self.request("GET", "/moved/repo.git/info/refs?service=git-upload-pack")
        self.assertEqual(resp.status, 301)
        self.assertEqual(resp.getheader("Location"), f"http://www.{self.up_host.partition(':')[0]}:{self.port}/new/repo.git/info/refs?service=git-upload-pack")

    # ── policy ───────────────────────────────────────────────────────────────────────────────
    def test_push_elsewhere_is_refused_before_upstream(self):
        for path in (
            "/group/upstream.git/info/refs?service=git-receive-pack",
            "/group/upstream.git/git-receive-pack",
            "/me/fork/../upstream.git/git-receive-pack",
            "/me/fork.git/evil.git/git-receive-pack",
        ):
            resp, _ = self.request("POST" if path.endswith("/git-receive-pack") else "GET", path, body=b"x")
            self.assertEqual(resp.status, 403, path)
        self.assertEqual(Upstream.seen, [])

    def test_duplicate_service_params_use_the_first_and_the_query_is_rebuilt(self):
        resp, _ = self.request("GET", "/x/y.git/info/refs?service=git-upload-pack&service=git-receive-pack&extra=1")
        self.assertEqual(resp.status, 200)
        self.assertEqual(Upstream.seen[0]["path"], "/x/y.git/info/refs?service=git-upload-pack")

    def test_upstream_401_becomes_403(self):
        resp, _ = self.request("GET", "/needs-auth/repo.git/info/refs?service=git-upload-pack")
        self.assertEqual(resp.status, 403)
        self.assertEqual(len(Upstream.seen), 1)

    def test_non_git_paths_and_unknown_hosts_are_404(self):
        for path in (
            "/me/fork.git/HEAD",
            "/api/v4/user",
            "/me/fork.git/info/lfs/objects/batch",
        ):
            resp, _ = self.request("GET", path)
            self.assertIn(resp.status, (403, 404), path)
        for host in ("www.evil.example", "evil.example", "github.com.evil.example", f"www.{self.up_host.partition(':')[0]}.evil", ""):
            resp, _ = self.request("GET", "/me/fork.git/info/refs?service=git-upload-pack", host=host)
            self.assertEqual(resp.status, 404, host)
        self.assertEqual(Upstream.seen, [])

    def test_host_is_taken_from_the_host_header_with_or_without_www(self):
        for host in (
            f"www.{self.up_host.partition(':')[0]}:{self.port}",
            f"{self.up_host.partition(':')[0]}:{self.port}",
            f"WWW.{self.up_host.partition(':')[0]}",
        ):
            resp, data = self.request("GET", "/x/y.git/info/refs?service=git-upload-pack", host=host)
            self.assertEqual((resp.status, data), (200, ADVERT), host)

    def test_refusal_closes_the_connection_explicitly(self):
        resp, _ = self.request("POST", "/other/repo.git/git-receive-pack", body=b"x")
        self.assertEqual(resp.status, 403)
        self.assertEqual(resp.getheader("Connection"), "close")

    def test_no_duplicate_server_or_date_headers(self):
        resp, _ = self.request("GET", "/x/y.git/info/refs?service=git-upload-pack")
        for name in ("Server", "Date"):
            self.assertEqual(len([k for k, _ in resp.getheaders() if k.lower() == name.lower()]), 1, name)

    def test_truncated_upstream_body_closes_instead_of_hanging(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/truncate/repo.git/info/refs?service=git-upload-pack")
        resp = conn.getresponse()
        self.assertEqual((resp.status, resp.getheader("Content-Length")), (200, "100"))
        # The proxy must close after the short body: http.client then raises IncompleteRead at once.
        # A proxy that kept the connection open would make this read block until the 5 s timeout.
        with self.assertRaises(http.client.IncompleteRead):
            resp.read()
        conn.close()

    def test_only_get_and_post(self):
        resp, _ = self.request("HEAD", "/me/fork.git/info/refs?service=git-upload-pack")
        self.assertEqual(resp.status, 501)
        resp, _ = self.request("POST", "/me/fork.git/info/refs?service=git-upload-pack", body=b"x")
        self.assertEqual(resp.status, 405)
        resp, _ = self.request("GET", "/me/fork.git/git-upload-pack")
        self.assertEqual(resp.status, 405)
        self.assertEqual(Upstream.seen, [])

    def test_serves_again_after_a_refusal(self):
        self.request("POST", "/other/repo.git/git-receive-pack", body=b"x")
        resp, data = self.request("GET", "/other/repo.git/info/refs?service=git-upload-pack")
        self.assertEqual((resp.status, data), (200, ADVERT))


class CredentialSelectionTest(unittest.TestCase):
    """credential(): the GitHub token only for this stack's repos; GitLab deploy token only for the fork."""

    @classmethod
    def setUpClass(cls):
        import importlib.util

        env = {
            "GH_TOKEN": "ghtok",
            "GITPROXY_READ": "github.com/Upstream/Repo",
            "GITPROXY_WRITE": "github.com/forkorg/repo,gl.example/me/fork",
            "GITLAB_HOST": "GL.example",
            "GITLAB_READ_TOKEN": "rt",
            "GITLAB_FORK_PATH": "me/fork",
            "GITLAB_DEPLOY_TOKEN": "dt",
        }
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            spec = importlib.util.spec_from_file_location("gitproxy_under_test", PROXY)
            cls.gp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.gp)
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)

    def test_github_token_only_for_listed_repos(self):
        cred = self.gp.credential
        self.assertEqual(cred("github.com", "upstream/repo.git"), ("x-access-token", "ghtok"))
        self.assertEqual(cred("github.com", "ForkOrg/Repo"), ("x-access-token", "ghtok"))
        self.assertIsNone(cred("github.com", "forkorg/other-stacks-private-fork.git"))
        self.assertIsNone(cred("github.com", "octocat/hello-world.git"))

    def test_gitlab_deploy_token_only_for_the_fork(self):
        cred = self.gp.credential
        self.assertEqual(cred("gl.example", "ME/FORK.git"), ("gitlab+deploy-token", "dt"))
        self.assertEqual(cred("gl.example", "group/upstream.git"), ("oauth2", "rt"))
        self.assertIsNone(cred("other.example", "me/fork"))

    def test_hosts_and_lists(self):
        self.assertEqual(self.gp.UPSTREAMS, {"github.com": "github.com", "gl.example": "gl.example"})
        self.assertEqual(self.gp.WRITE, {"github.com/forkorg/repo", "gl.example/me/fork"})
        self.assertEqual(self.gp.READ, {"github.com/upstream/repo", "github.com/forkorg/repo", "gl.example/me/fork"})


class GitProxyStartupTest(unittest.TestCase):
    def test_refuses_to_start_with_nothing_to_serve(self):
        proc = subprocess.run([sys.executable, "-I", str(PROXY)], env={"PATH": os.environ["PATH"]}, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("nothing to serve", proc.stderr)


if __name__ == "__main__":
    unittest.main()
