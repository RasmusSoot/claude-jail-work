"""kind-stack.sh: the policies it renders from a stack conf (no Docker, no cluster needed).

`registry-config` prints the Zot configuration `up` writes; this checks the shape that makes the
sidecar's allowlist a boundary: anyone reads, one user writes exactly the names in BUILD_NAMES
(plus their cache and chart paths), nothing is deletable, and the Docker-manifest compat the CNB
lifecycle needs is on. `addons-render` prints the `platform` AppProject for KIND_ADDONS; this
checks that it lists exactly what the addon files declare and that a file saying anything else is
refused. Stdlib only.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

KIND_STACK = Path(__file__).resolve().parents[1] / "tools" / "kind-stack.sh"


REPO_ADDONS = KIND_STACK.parents[1] / "addons"


def run(conf: str, action: str, user: str = "pusher", addons: dict[str, str] | None = None, stack: str = "t") -> str:
    """`addons` replaces the repo's addons/ dir with {name: file text} (KIND_ADDONS_DIR)."""
    with tempfile.TemporaryDirectory(prefix="kind-stack-test-") as tmp:
        path = Path(tmp) / "t.conf"
        path.write_text(conf)
        env = {**os.environ, "KIND_STACK_CONF": str(path), "REGISTRY_PUSH_USER": user, "NO_COLOR": "1"}
        if addons is not None:
            (Path(tmp) / "addons").mkdir()
            for name, text in addons.items():
                (Path(tmp) / "addons" / f"{name}.yaml").write_text(text)
            env["KIND_ADDONS_DIR"] = str(Path(tmp) / "addons")
        out = subprocess.run(["bash", str(KIND_STACK), stack, action], env=env, capture_output=True, text=True, timeout=120)
    if out.returncode != 0:
        raise RuntimeError(out.stderr)
    return out.stdout


def render(conf: str, user: str = "pusher") -> dict:
    return json.loads(run(conf, "registry-config", user))


class ArgoPolicyTest(unittest.TestCase):
    """`argo-policy` is what the launcher's gate requires argocd-rbac-cm to equal: get, sync and logs
    on the stack's project, the project itself readable, one grouping line, nothing else."""

    def test_policy_is_get_sync_logs_on_the_project_only(self):
        lines = run("KIND_CLUSTER=t\n", "argo-policy").splitlines()
        self.assertEqual(
            lines,
            [
                "p, role:t-jail, applications, get, t/*, allow",
                "p, role:t-jail, applications, sync, t/*, allow",
                "p, role:t-jail, logs, get, t/*, allow",
                "p, role:t-jail, projects, get, t, allow",
                "g, t-jail, role:t-jail",
            ],
        )
        for line in lines:
            if line.startswith("p, "):
                self.assertIn(line.split(", ")[3], ("get", "sync"))  # the action column, never a write or `*`


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


KPS = (REPO_ADDONS / "kube-prometheus-stack.yaml").read_text()


class AddonsProjectTest(unittest.TestCase):
    """`addons-render` is the `platform` AppProject `up` applies: its sources and destinations are
    exactly what the listed addon files declare, never `*`; cluster-scoped kinds are the point."""

    def test_project_lists_exactly_the_addon_files_repo_and_namespace(self):
        proj = json.loads(run('KIND_CLUSTER=t\nKIND_ADDONS="kube-prometheus-stack"\n', "addons-render"))
        self.assertEqual((proj["kind"], proj["metadata"]), ("AppProject", {"name": "platform", "namespace": "argocd"}))
        spec = proj["spec"]
        self.assertEqual(spec["sourceRepos"], ["https://prometheus-community.github.io/helm-charts"])
        self.assertEqual(spec["destinations"], [{"server": "https://kubernetes.default.svc", "namespace": "monitoring"}])
        self.assertEqual(spec["clusterResourceWhitelist"], [{"group": "*", "kind": "*"}])
        self.assertEqual(set(spec), {"description", "sourceRepos", "destinations", "clusterResourceWhitelist"})

    def test_repos_and_namespaces_are_deduplicated_across_files(self):
        other = KPS.replace("name: kube-prometheus-stack\n  namespace: argocd", "name: other\n  namespace: argocd", 1)
        other = other.replace("namespace: monitoring", "namespace: other-ns")
        proj = json.loads(
            run('KIND_CLUSTER=t\nKIND_ADDONS="kube-prometheus-stack other"\n', "addons-render", addons={"kube-prometheus-stack": KPS, "other": other})
        )
        self.assertEqual(proj["spec"]["sourceRepos"], ["https://prometheus-community.github.io/helm-charts"])
        self.assertEqual([d["namespace"] for d in proj["spec"]["destinations"]], ["monitoring", "other-ns"])

    def test_up_with_addons_but_no_argo_apps_fails_before_making_anything(self):
        with self.assertRaises(RuntimeError) as cm:  # exits before the first docker or kind call
            run('KIND_CLUSTER=t\nKIND_ADDONS="kube-prometheus-stack"\n', "up")
        self.assertIn("ARGO_APPS", str(cm.exception))

    def test_no_addons_renders_nothing(self):
        self.assertEqual(run("KIND_CLUSTER=t\n", "addons-render"), "")

    def test_the_jail_policy_does_not_change_with_addons(self):
        conf = "KIND_CLUSTER=t\n"
        self.assertEqual(run(conf, "argo-policy"), run(conf + 'KIND_ADDONS="kube-prometheus-stack"\n', "argo-policy"))

    def refused(self, text: str, name: str = "kube-prometheus-stack", conf: str = "", stack: str = "t") -> str:
        with self.assertRaises(RuntimeError) as cm:
            run(f'KIND_CLUSTER=t\nKIND_ADDONS="{name}"\n{conf}', "addons-render", addons={name: text} if text else {}, stack=stack)
        return str(cm.exception)

    def test_unknown_addon_name_is_refused(self):
        with self.assertRaises(RuntimeError) as cm:
            run('KIND_CLUSTER=t\nKIND_ADDONS="no-such-addon"\n', "addons-render")
        self.assertIn("no-such-addon", str(cm.exception))

    def test_a_name_that_is_a_path_is_refused(self):
        self.assertIn("not an addon name", self.refused("", name="../stacks/t"))

    def test_a_file_outside_project_platform_is_refused(self):
        self.assertIn("spec.project", self.refused(KPS.replace("project: platform", "project: t")))

    def test_a_file_whose_name_or_namespace_differs_is_refused(self):
        self.assertIn("metadata.name", self.refused(KPS.replace("name: kube-prometheus-stack\n", "name: other\n", 1)))
        self.assertIn("metadata.namespace", self.refused(KPS.replace("namespace: argocd", "namespace: t", 1)))

    def test_a_second_document_is_refused(self):
        self.assertIn("a --- line", self.refused(KPS + "---\napiVersion: v1\nkind: Namespace\n"))

    def test_the_stack_registry_or_a_floating_version_as_source_is_refused(self):
        repo = "https://prometheus-community.github.io/helm-charts"
        self.assertIn("repoURL", self.refused(KPS.replace(repo, "jail-t-registry:5000/charts")))
        self.assertIn("targetRevision", self.refused(KPS.replace("targetRevision: 91.9.0", 'targetRevision: "*"')))

    def test_a_shared_namespace_as_destination_is_refused(self):
        for ns in ("argocd", "t", "kube-system"):
            self.assertIn("namespace of its own", self.refused(KPS.replace("namespace: monitoring", f"namespace: {ns}")), ns)

    def test_multi_source_is_refused(self):
        multi = KPS.replace("  source:\n", "  sources:\n  - chart: x\n    repoURL: https://example.org/charts\n  source:\n", 1)
        self.assertIn("spec.sources", self.refused(multi))

    def test_a_plain_http_or_port_bearing_repo_is_refused(self):
        repo = "https://prometheus-community.github.io/helm-charts"
        self.assertIn("repoURL", self.refused(KPS.replace(repo, "http://prometheus-community.github.io/helm-charts")))
        self.assertIn("repoURL", self.refused(KPS.replace(repo, "https://prometheus-community.github.io:8443/helm-charts")))

    def test_a_git_path_source_without_chart_is_refused(self):
        msg = self.refused(KPS.replace("chart: kube-prometheus-stack", "path: charts/kube-prometheus-stack"))
        self.assertIn("spec.source.path", msg)

    def test_value_files_are_refused(self):
        msg = self.refused(KPS.replace("      valuesObject:\n", "      valueFiles: [values-kind.yaml]\n      valuesObject:\n", 1))
        self.assertIn("valueFiles", msg)

    def test_a_quoted_key_is_refused(self):
        self.assertIn("quoted key", self.refused(KPS.replace("  project: platform", '  project: platform\n  "project": t')))

    def test_a_stack_named_platform_is_refused(self):
        self.assertIn("platform", self.refused(KPS, stack="platform"))

    def test_a_name_in_both_argo_apps_and_addons_is_refused(self):
        self.assertIn("both", self.refused(KPS, conf='ARGO_APPS="kube-prometheus-stack"\n'))


if __name__ == "__main__":
    unittest.main()
