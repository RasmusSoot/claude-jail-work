"""upload server end-to-end: start it, push a file through, check what lands on disk. Stdlib only."""

from __future__ import annotations

import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

UPLOAD = Path(__file__).resolve().parents[1] / "tools" / "upload" / "upload.py"
TOKEN = "test-token-0123456789abcdef"


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


class UploadTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="upload-test-")
        cls.inbox = Path(cls.tmp.name) / "inbox"
        cls.port = free_port()
        cls.errlog = open(Path(cls.tmp.name) / "server.log", "w")  # the server's stderr: checked for leaks at teardown
        cls.proc = subprocess.Popen(
            [sys.executable, "-I", str(UPLOAD), "--dir", str(cls.inbox), "--port", str(cls.port), "--host", "127.0.0.1", "--max-mib", "1"],
            env={"PATH": os.environ["PATH"], "UPLOAD_TOKEN": TOKEN},
            stdout=subprocess.DEVNULL,
            stderr=cls.errlog,
        )
        wait_port(cls.port)

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(5)
        cls.errlog.close()
        log = (Path(cls.tmp.name) / "server.log").read_text()
        cls.tmp.cleanup()
        # The request line of GET /?t=<token> is logged: the query must be stripped from it.
        assert "GET /" in log, "nothing logged"
        assert TOKEN not in log and "?t=" not in log, "the upload token leaked into the server log"

    def request(self, method: str, path: str, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp, data

    def upload(self, name: str, body: bytes, token: str = TOKEN):
        resp, data = self.request("POST", "/upload", body=body, headers={"X-Upload-Token": token, "X-Filename": name})
        return resp.status, json.loads(data)

    def test_page_needs_the_token(self):
        self.assertEqual(self.request("GET", "/")[0].status, 403)
        self.assertEqual(self.request("GET", "/?t=wrong")[0].status, 403)
        resp, data = self.request("GET", f"/?t={TOKEN}")
        self.assertEqual(resp.status, 200)
        self.assertIn(b"<!doctype html>", data)
        self.assertIn(json.dumps(TOKEN).encode(), data)  # the page carries the token for its own uploads

    def test_upload_lands_in_the_inbox(self):
        status, j = self.upload("notes.txt", b"hello\n")
        self.assertEqual((status, j["ok"], j["name"], j["size"]), (200, True, "notes.txt", 6))
        self.assertEqual((self.inbox / "notes.txt").read_bytes(), b"hello\n")

    def test_filename_is_sanitised_and_stays_inside_the_inbox(self):
        status, j = self.upload("../../etc/pa%20sswd", b"x")
        self.assertEqual(status, 200)
        self.assertEqual(j["name"], "pa sswd")
        self.assertEqual(Path(j["path"]).parent, self.inbox.resolve())
        self.assertFalse((self.inbox.parent / "etc").exists())

    def test_dot_only_names_stay_inside_the_inbox(self):
        # "." resolves to the inbox itself; the uniqueness fallback would then have named a sibling of it
        before = {p.name for p in self.inbox.parent.iterdir()}
        for name in (".", "..", "..."):
            status, body = self.upload(name, b"dots")
            self.assertEqual(status, 200, name)
            self.assertEqual(Path(body["path"]).parent, self.inbox, name)
            self.assertTrue(Path(body["path"]).is_file(), name)
        self.assertEqual({p.name for p in self.inbox.parent.iterdir()}, before)

    def test_name_collisions_do_not_overwrite(self):
        self.upload("same.bin", b"first")
        status, j = self.upload("same.bin", b"second")
        self.assertEqual((status, j["name"]), (200, "same-1.bin"))
        self.assertEqual((self.inbox / "same.bin").read_bytes(), b"first")
        self.assertEqual((self.inbox / "same-1.bin").read_bytes(), b"second")

    def test_bad_token_empty_body_and_oversize_are_refused(self):
        self.assertEqual(self.upload("a.txt", b"x", token="nope")[0], 403)
        self.assertEqual(self.upload("a.txt", b"")[0], 400)
        resp, data = self.request("POST", "/upload", body=b"x", headers={"X-Upload-Token": TOKEN, "X-Filename": "big.bin", "Content-Length": str(2 * 2**20)})
        self.assertEqual(resp.status, 413)
        self.assertFalse((self.inbox / "a.txt").exists())
        self.assertFalse((self.inbox / "big.bin").exists())

    def test_other_paths_are_404(self):
        self.assertEqual(self.request("GET", f"/notes.txt?t={TOKEN}")[0].status, 404)
        self.assertEqual(self.request("POST", "/", body=b"x", headers={"X-Upload-Token": TOKEN})[0].status, 404)


class UploadStartupTest(unittest.TestCase):
    def test_refuses_to_serve_without_a_real_token(self):
        for token in ("", "short"):
            proc = subprocess.run(
                [sys.executable, "-I", str(UPLOAD), "--dir", tempfile.mkdtemp(), "--port", str(free_port())],
                env={"PATH": os.environ["PATH"], "UPLOAD_TOKEN": token},
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(proc.returncode, 2, token)
            self.assertIn("refusing to serve without auth", proc.stderr)


if __name__ == "__main__":
    unittest.main()
