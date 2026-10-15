"""build sidecar loop end-to-end: tools/builder/builder.sh against a fake CNB lifecycle and a fake helm.

The real creator and helm are replaced by scripts on PATH that record their arguments and
environment, so the test checks the protocol (request dir in, result.env out), the policy (name
allowlist, chart name match, credential never on the jail-visible side) and the paths (pack's
/workspace and /layers, cleared before each build). Stdlib only.
"""

from __future__ import annotations

import base64
import os
import subprocess
import tarfile
import tempfile
import time
import unittest
from pathlib import Path

BUILDER = Path(__file__).resolve().parents[1] / "tools" / "builder" / "builder.sh"
REGISTRY = "reg.test:5000"

FAKE_CREATOR = r"""#!/usr/bin/env bash
# Records argv and env, checks the app arrived and the layers dir is empty, writes the report.
set -eu
me="$(dirname "$0")/../.."
printf '%s\n' "$@" > "$me/creator.args"
env | sort > "$me/creator.env"
app=""; layers=""; report=""; platform=""
while [ $# -gt 1 ]; do case "$1" in -app) app="$2";; -layers) layers="$2";; -report) report="$2";; -platform) platform="$2";; esac; shift; done
[ -f "$app/BOOT-INF/marker" ] || { echo "app not copied to $app"; exit 1; }
rm -rf "$me/platform.env"; cp -r "$platform/env" "$me/platform.env"
printf '%s\n' "$platform" "$report" > "$me/creator.paths"
[ -z "$(ls -A "$layers")" ] || { echo "layers not cleared: $(ls -A "$layers")"; exit 1; }
[ "${FAKE_CREATOR_FAIL:-}" = 1 ] && { echo "boom"; exit 1; }
printf '[image]\ndigest = "sha256:0000"\n' > "$report"
echo "creator ok"
"""

FAKE_HELM = r"""#!/usr/bin/env bash
set -eu
me="$(dirname "$0")/.."
case "$1" in
  show)  tar -xzOf "$3" --wildcards '*/Chart.yaml' ;;
  push)  [ "${FAKE_HELM_PUSH_FAIL:-}" = 1 ] && { echo "push denied"; exit 1; }
         printf '%s\n' "$@" > "$me/helm.args"; cp "$HELM_REGISTRY_CONFIG" "$me/helm.registry.json"
         echo "Pushed: $3/x"; echo "Digest: sha256:c0ffee" ;;
  *)     echo "unexpected helm $1" >&2; exit 1 ;;
esac
"""


def chart_tgz(path: Path, name: str) -> None:
    chart = path.parent / f"src-{name}"
    chart.mkdir()
    (chart / "Chart.yaml").write_text(f"apiVersion: v2\nname: {name}\nversion: 0.1.0\n")
    with tarfile.open(path, "w:gz") as t:
        t.add(chart, arcname=name)


class BuilderTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="builder-test-")
        self.root = Path(self.tmp.name)
        self.cnb = self.root / "cnb"
        (self.cnb / "lifecycle").mkdir(parents=True)
        (self.cnb / "run.toml").write_text('[[images]]\nimage = "run.test/img"\n')
        creator = self.cnb / "lifecycle" / "creator"
        creator.write_text(FAKE_CREATOR)
        creator.chmod(0o755)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        helm = self.bin / "helm"
        helm.write_text(FAKE_HELM)
        helm.chmod(0o755)
        for d in ("build", "work", "layers", "home", "reqtmp"):
            (self.root / d).mkdir()
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(5)
        if getattr(self, "log", None):
            self.log.close()
        self.tmp.cleanup()

    def start(self, names="demo other", **extra_env) -> subprocess.Popen:
        env = {
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "HOME": str(self.root / "home"),
            "BUILD_ROOT": str(self.root / "build"),
            "CNB_ROOT": str(self.cnb),
            "WORK_DIR": str(self.root / "work"),
            "LAYERS_DIR": str(self.root / "layers"),
            "REQ_TMP_DIR": str(self.root / "reqtmp"),
            "BUILD_REGISTRY": REGISTRY,
            "BUILD_NAMES": names,
            "BUILDER_PLATFORM_API": "0.15",
            **extra_env,
        }
        if getattr(self, "log", None):
            self.log.close()  # a test may start the sidecar twice
        self.log = open(self.root / "sidecar.log", "w")
        self.proc = subprocess.Popen(["bash", str(BUILDER)], env=env, stdout=self.log, stderr=subprocess.STDOUT)
        end = time.monotonic() + 5
        while time.monotonic() < end:
            if "jail-builder: serving" in (self.root / "sidecar.log").read_text():
                return self.proc
            if self.proc.poll() is not None:
                break
            time.sleep(0.05)
        raise RuntimeError("sidecar did not start:\n" + (self.root / "sidecar.log").read_text())

    def wait_result(self, d: Path, timeout: float = 10) -> dict:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if (d / "result.env").exists():
                return dict(line.split("=", 1) for line in (d / "result.env").read_text().splitlines() if "=" in line)
            time.sleep(0.05)
        raise RuntimeError(f"no result for {d.name}:\n" + ((d / "log").read_text() if (d / "log").exists() else "no log"))

    def request(self, rid: str, image: str, chart: str | None = None, chart_name: str | None = None, extra: str = "") -> dict:
        d = self.root / "build" / rid
        (d / "app" / "BOOT-INF").mkdir(parents=True)
        (d / "app" / "BOOT-INF" / "marker").write_text("x")
        lines = [f"IMAGE={image}"]
        if chart is not None:
            lines.append(f"CHART={chart}")
        if chart_name is not None:
            chart_tgz(d / "chart.tgz", chart_name)
        (d / "request.env").write_text("\n".join(lines) + extra + "\n")
        (d / "request").write_text("")
        return self.wait_result(d)

    # ── the happy path and the paths ──────────────────────────────────────────────────────────────

    def test_image_build_uses_pack_paths_and_reports_the_digest(self):
        self.start()
        (self.root / "layers" / "stale").write_text("left over from the previous build")
        res = self.request("r1", "demo:1")
        self.assertEqual(res["STATUS"], "ok")
        self.assertEqual(res["IMAGE"], f"{REGISTRY}/demo:1")
        self.assertEqual(res["IMAGE_DIGEST"], "sha256:0000")
        args = (self.root / "creator.args").read_text().split("\n")
        self.assertEqual(args[args.index("-app") + 1], str(self.root / "work"))
        self.assertEqual(args[args.index("-layers") + 1], str(self.root / "layers"))
        self.assertEqual(args[args.index("-cache-image") + 1], f"{REGISTRY}/demo-cache")
        self.assertEqual(args[args.index("-run-image") + 1], "run.test/img")
        self.assertIn(f"{REGISTRY}/demo:1", args)
        env = (self.root / "creator.env").read_text()
        self.assertIn("CNB_PLATFORM_API=0.15", env)
        self.assertIn(f"CNB_INSECURE_REGISTRIES={REGISTRY.split('/')[0]}", env)
        self.assertIn(f"CNB_USER_ID={os.getuid()}", env)
        self.assertFalse((self.root / "layers" / "stale").exists())

    def test_buildpack_env_becomes_platform_files_and_other_keys_are_ignored(self):
        self.start()
        self.request("r1", "demo:1", extra="\nBP_JVM_VERSION=21\nBPL_X=y\nEVIL=1")
        plat = self.root / "platform.env"
        self.assertEqual((plat / "BP_JVM_VERSION").read_text(), "21")
        self.assertEqual((plat / "BPL_X").read_text(), "y")
        self.assertFalse((plat / "EVIL").exists())
        self.assertIn("ignoring key: EVIL", (self.root / "build" / "r1" / "log").read_text())

    def test_request_is_read_from_a_tmpfs_copy_that_is_gone_afterwards(self):
        # The sidecar's platform dir and report live in its own /tmp copy, not in the shared request
        # dir, and the copy is removed after the build: nothing of the sidecar's is left for the jail
        # to swap under the next build, and nothing read from the jail-written dir after `started`.
        self.start()
        self.request("r1", "demo:1")
        platform, report = (self.root / "creator.paths").read_text().split("\n")[:2]
        copy = self.root / "reqtmp" / "req-r1"  # /tmp/req-<id> in the sidecar (its tmpfs)
        self.assertEqual(Path(platform), copy / "platform")
        self.assertEqual(Path(report), copy / "report.toml")
        end = time.monotonic() + 3  # removed right after result.env is renamed into place: wait for it
        while copy.exists() and time.monotonic() < end:
            time.sleep(0.05)
        self.assertFalse(copy.exists())
        req = self.root / "build" / "r1"
        self.assertEqual(sorted(p.name for p in req.iterdir()), ["app", "log", "request", "request.env", "result.env", "started"])

    def test_fifo_in_the_request_is_refused_without_reading_it(self):
        self.start()
        d = self.root / "build" / "r1"
        (d / "app" / "BOOT-INF").mkdir(parents=True)
        (d / "app" / "BOOT-INF" / "marker").write_text("x")
        os.mkfifo(d / "request.env")  # a read would block the sidecar forever
        (d / "request").write_text("")
        res = self.wait_result(d)
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("symlink or special file", (d / "log").read_text())
        self.assertFalse((self.root / "creator.args").exists())

    def test_failed_lifecycle_is_reported_and_the_loop_keeps_serving(self):
        self.start(FAKE_CREATOR_FAIL="1")
        res = self.request("r1", "demo:1")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("boom", (self.root / "build" / "r1" / "log").read_text())
        self.assertIsNone(self.proc.poll())

    # ── the policy ────────────────────────────────────────────────────────────────────────────────

    def test_name_outside_the_allowlist_is_refused_before_anything_runs(self):
        self.start()
        res = self.request("r1", "foreign:1")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("not in BUILD_NAMES", (self.root / "build" / "r1" / "log").read_text())
        self.assertFalse((self.root / "creator.args").exists())

    def test_malformed_image_reference_is_refused(self):
        self.start()
        for bad in ("demo", "Demo:1", "demo:bad tag", "demo:1:2", "../demo:1"):
            res = self.request(f"r-{abs(hash(bad))}", bad)
            self.assertEqual(res["STATUS"], "failed", bad)
        self.assertFalse((self.root / "creator.args").exists())

    def test_chart_is_pushed_after_the_image_with_its_digest(self):
        self.start()
        res = self.request("r1", "demo:1", chart="demo", chart_name="demo")
        self.assertEqual(res["STATUS"], "ok")
        self.assertEqual(res["CHART"], "demo")
        self.assertEqual(res["CHART_DIGEST"], "sha256:c0ffee")
        args = (self.root / "helm.args").read_text().split("\n")
        self.assertEqual(args[0], "push")
        self.assertEqual(args[2], f"oci://{REGISTRY}/charts")
        self.assertIn("--plain-http", args)

    def test_chart_whose_name_differs_from_the_request_is_refused(self):
        self.start()
        res = self.request("r1", "demo:1", chart="demo", chart_name="other")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("must match", (self.root / "build" / "r1" / "log").read_text())
        self.assertFalse((self.root / "creator.args").exists())

    def test_chart_outside_the_allowlist_is_refused_even_if_consistent(self):
        self.start(names="demo")
        res = self.request("r1", "demo:1", chart="foreign", chart_name="foreign")
        self.assertEqual(res["STATUS"], "failed")
        self.assertFalse((self.root / "creator.args").exists())

    def test_chart_declared_without_a_tarball_is_refused(self):
        self.start()
        res = self.request("r1", "demo:1", chart="demo")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("no chart.tgz", (self.root / "build" / "r1" / "log").read_text())

    def chart_only(self, rid: str, chart: str, chart_name: str | None) -> dict:
        d = self.root / "build" / rid
        d.mkdir(parents=True)
        if chart_name is not None:
            chart_tgz(d / "chart.tgz", chart_name)
        (d / "request.env").write_text(f"CHART={chart}\n")
        (d / "request").write_text("")
        return self.wait_result(d)

    def test_chart_only_request_pushes_the_chart_without_running_the_lifecycle(self):
        self.start(names="demo lab")
        res = self.chart_only("r1", "lab", "lab")
        self.assertEqual(res["STATUS"], "ok")
        self.assertEqual(res["CHART"], "lab")
        self.assertEqual(res["CHART_DIGEST"], "sha256:c0ffee")
        self.assertNotIn("IMAGE", res)
        self.assertFalse((self.root / "creator.args").exists())
        self.assertEqual((self.root / "helm.args").read_text().split("\n")[2], f"oci://{REGISTRY}/charts")

    def test_chart_only_outside_the_allowlist_is_refused(self):
        self.start(names="demo")
        res = self.chart_only("r1", "lab", "lab")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("be in BUILD_NAMES", (self.root / "build" / "r1" / "log").read_text())
        self.assertFalse((self.root / "helm.args").exists())

    def test_chart_only_whose_tarball_names_another_chart_is_refused(self):
        self.start(names="demo lab")
        res = self.chart_only("r1", "lab", "demo")
        self.assertEqual(res["STATUS"], "failed")
        self.assertFalse((self.root / "helm.args").exists())

    def test_chart_only_push_failure_is_reported(self):
        self.start(names="lab", FAKE_HELM_PUSH_FAIL="1")
        res = self.chart_only("r1", "lab", "lab")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("push denied", (self.root / "build" / "r1" / "log").read_text())

    def test_chart_only_with_a_symlinked_tarball_is_refused(self):
        self.start(names="lab")
        d = self.root / "build" / "r1"
        d.mkdir(parents=True)
        chart_tgz(self.root / "real.tgz", "lab")
        (d / "chart.tgz").symlink_to(self.root / "real.tgz")
        (d / "request.env").write_text("CHART=lab\n")
        (d / "request").write_text("")
        self.assertEqual(self.wait_result(d)["STATUS"], "failed")
        self.assertFalse((self.root / "helm.args").exists())

    def test_a_chart_name_that_is_not_a_name_is_refused(self):
        self.start(names="demo lab")
        res = self.chart_only("r1", "demo lab", "demo lab")
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("is not a chart name", (self.root / "build" / "r1" / "log").read_text())

    def test_chart_only_without_a_tarball_is_refused(self):
        self.start(names="lab")
        res = self.chart_only("r1", "lab", None)
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("no chart.tgz", (self.root / "build" / "r1" / "log").read_text())

    # ── symlinks and paths: the sidecar reads what the jail cannot, so a request must not point anywhere ─

    def test_symlinked_app_dir_is_refused(self):
        self.start()
        elsewhere = self.root / "elsewhere" / "BOOT-INF"
        elsewhere.mkdir(parents=True)
        (elsewhere / "marker").write_text("x")
        d = self.root / "build" / "r1"
        d.mkdir()
        (d / "app").symlink_to(self.root / "elsewhere")
        (d / "request.env").write_text("IMAGE=demo:1\n")
        (d / "request").write_text("")
        res = self.wait_result(d)
        self.assertEqual(res["STATUS"], "failed")
        self.assertIn("symlink", (d / "log").read_text())
        self.assertFalse((self.root / "creator.args").exists())
        self.assertFalse((self.root / "work" / "BOOT-INF").exists())

    def test_symlink_inside_the_app_is_refused(self):
        self.start()
        d = self.root / "build" / "r1"
        (d / "app" / "BOOT-INF").mkdir(parents=True)
        (d / "app" / "BOOT-INF" / "marker").write_text("x")
        (d / "app" / "secret").symlink_to(self.root / "sidecar.log")
        (d / "request.env").write_text("IMAGE=demo:1\n")
        (d / "request").write_text("")
        res = self.wait_result(d)
        self.assertEqual(res["STATUS"], "failed")
        self.assertFalse((self.root / "creator.args").exists())

    def test_symlinked_request_dir_is_ignored(self):
        self.start()
        real = self.root / "elsewhere"
        (real / "app" / "BOOT-INF").mkdir(parents=True)
        (real / "app" / "BOOT-INF" / "marker").write_text("x")
        (real / "request.env").write_text("IMAGE=demo:1\n")
        (real / "request").write_text("")
        (self.root / "build" / "r1").symlink_to(real)
        end = time.monotonic() + 3
        while time.monotonic() < end and "request dir is a symlink" not in (self.root / "sidecar.log").read_text():
            time.sleep(0.05)
        self.assertIn("r1: refused — the request dir is a symlink", (self.root / "sidecar.log").read_text())
        self.assertFalse((real / "started").exists())
        self.assertFalse((real / "result.env").exists())

    def test_env_key_with_a_path_in_it_is_ignored(self):
        self.start()
        self.request("r1", "demo:1", extra="\nBP_A/../../../escaped=1\nBP_OK=2")
        self.assertFalse((self.root / "build" / "escaped").exists())
        self.assertFalse((self.root / "escaped").exists())
        self.assertEqual(sorted(p.name for p in (self.root / "platform.env").iterdir()), ["BP_OK"])
        self.assertIn("ignoring key: BP_A/../../../escaped", (self.root / "build" / "r1" / "log").read_text())

    # ── the credential ────────────────────────────────────────────────────────────────────────────

    def test_credential_reaches_lifecycle_and_helm_but_never_the_request_dir(self):
        self.start(REGISTRY_PUSH_USER="pusher", REGISTRY_PUSH_PASSWORD="s3cret")
        res = self.request("r1", "demo:1", chart="demo", chart_name="demo")
        self.assertEqual(res["STATUS"], "ok")
        env = (self.root / "creator.env").read_text()
        basic = base64.b64encode(b"pusher:s3cret").decode()  # computed, so no credential-shaped literal sits in the repo (gitleaks)
        self.assertIn(f'CNB_REGISTRY_AUTH={{"{REGISTRY}":"Basic {basic}"}}', env)
        self.assertNotIn("REGISTRY_PUSH_PASSWORD", env)
        self.assertNotIn("REGISTRY_PUSH_USER", env)
        self.assertIn(f'"auth":"{basic}"', (self.root / "helm.registry.json").read_text())
        self.assertIn("auth=yes", (self.root / "sidecar.log").read_text())
        for f in (self.root / "build").rglob("*"):
            if f.is_file():
                self.assertNotIn("s3cret", f.read_text(errors="replace"), f)

    def test_without_credential_the_auth_file_is_empty_and_the_log_says_so(self):
        self.start()
        self.request("r1", "demo:1", chart="demo", chart_name="demo")
        self.assertIn('{"auths":{}}', (self.root / "helm.registry.json").read_text())
        self.assertIn("auth=no", (self.root / "sidecar.log").read_text())

    # ── startup gates ─────────────────────────────────────────────────────────────────────────────

    def test_refuses_to_start_without_a_platform_api_or_a_writable_layers_dir(self):
        (self.root / "layers").rmdir()
        with self.assertRaises(RuntimeError) as cm:
            self.start()
        self.assertIn("not a writable directory", str(cm.exception))
        self.assertEqual(self.proc.wait(5), 2)
        (self.root / "layers").mkdir()
        with self.assertRaises(RuntimeError) as cm:
            self.start(BUILDER_PLATFORM_API="")
        self.assertIn("cannot read the platform API", str(cm.exception))
        self.assertEqual(self.proc.wait(5), 2)


if __name__ == "__main__":
    unittest.main()
