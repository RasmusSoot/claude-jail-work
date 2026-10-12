"""kind-stack.sh: the registry policy it renders from a stack conf (no Docker, no cluster needed).

`registry-config` prints the Zot configuration `up` writes; this checks the shape that makes the
sidecar's allowlist a boundary: anyone reads, one user writes exactly the names in BUILD_NAMES
(plus their cache and chart paths), nothing is deletable, and the Docker-manifest compat the CNB
lifecycle needs is on. Stdlib only.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

KIND_STACK = Path(__file__).resolve().parents[1] / "tools" / "kind-stack.sh"


def render(conf: str, user: str = "pusher") -> dict:
    with tempfile.TemporaryDirectory(prefix="kind-stack-test-") as tmp:
        path = Path(tmp) / "t.conf"
        path.write_text(conf)
        env = {**os.environ, "KIND_STACK_CONF": str(path), "REGISTRY_PUSH_USER": user, "NO_COLOR": "1"}
        out = subprocess.run(["bash", str(KIND_STACK), "t", "registry-config"], env=env, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return json.loads(out.stdout)


class RegistryPolicyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cfg = render('KIND_CLUSTER=t\nBUILD_NAMES="app other"\n')
        cls.repos = cls.cfg["http"]["accessControl"]["repositories"]

    def test_anyone_reads_everything_and_nothing_more(self):
        self.assertEqual(self.repos["**"], {"anonymousPolicy": ["read"], "defaultPolicy": ["read"]})

    def test_push_user_writes_exactly_the_listed_names_cache_and_charts(self):
        expected = {"app", "app-cache", "charts/app", "other", "other-cache", "charts/other"}
        self.assertEqual(set(self.repos) - {"**"}, expected)
        for name in expected:
            entry = self.repos[name]
            self.assertEqual(entry["anonymousPolicy"], ["read"], name)
            self.assertEqual(entry["defaultPolicy"], ["read"], name)
            self.assertEqual(entry["policies"], [{"users": ["pusher"], "actions": ["read", "create", "update"]}], name)

    def test_no_delete_anywhere_and_no_admin_policy(self):
        for name, entry in self.repos.items():
            for policy in entry.get("policies", []):
                self.assertNotIn("delete", policy["actions"], name)
        self.assertNotIn("adminPolicy", self.cfg["http"]["accessControl"])

    def test_auth_is_htpasswd_at_the_mounted_path_on_the_plain_port(self):
        http = self.cfg["http"]
        self.assertEqual(http["auth"], {"htpasswd": {"path": "/etc/zot/htpasswd"}})
        self.assertEqual((http["address"], http["port"]), ("0.0.0.0", "5000"))
        self.assertNotIn("tls", http)

    def test_docker_schema2_manifests_are_accepted_for_the_lifecycle(self):
        self.assertEqual(self.cfg["http"]["compat"], ["docker2s2"])

    def test_storage_is_the_mounted_volume_with_gc(self):
        self.assertEqual(self.cfg["storage"]["rootDirectory"], "/var/lib/registry")
        self.assertTrue(self.cfg["storage"]["gc"])

    def test_empty_build_names_leaves_only_anonymous_read(self):
        cfg = render("KIND_CLUSTER=t\n")
        self.assertEqual(list(cfg["http"]["accessControl"]["repositories"]), ["**"])

    def test_conf_without_a_cluster_is_refused(self):
        with self.assertRaises(RuntimeError) as cm:
            render("BUILD_NAMES=app\n")
        self.assertIn("KIND_CLUSTER", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
