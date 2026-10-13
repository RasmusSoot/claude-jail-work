"""tools/gitdir-scan.sh: what the launcher's record check and the exit audit see under a stack home.

A temp stack home with repo dirs in the shapes a session could leave behind. The scan must name a
top-level .git directory (with its inode), refuse pointer files, symlinks and submodule dirs, report
nested .git entries of every kind — inside local-only dirs and the build dir too — and treat a
directory it cannot read as a refusal, not as empty. It runs find and ls only, never git.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCAN = Path(__file__).resolve().parents[1] / "tools" / "gitdir-scan.sh"


def scan(home: Path, *names: str) -> list[list[str]]:
    out = subprocess.run(["bash", str(SCAN), str(home), *names], capture_output=True, text=True, timeout=30)
    assert out.returncode == 0, out.stderr
    rows = [line.split("\t") for line in out.stdout.splitlines()]
    assert rows[-1] == ["end"], rows  # the caller's proof that the scan ran to the end
    return rows[:-1]


class GitdirScanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gitdir-scan-")
        self.home = Path(self.tmp.name)

    def tearDown(self):
        for root, dirs, _files in os.walk(self.home):  # undo chmod 000 so cleanup works
            for d in dirs:
                os.chmod(Path(root) / d, 0o700)
        self.tmp.cleanup()

    def repo(self, name: str) -> Path:
        d = self.home / name
        (d / ".git").mkdir(parents=True)
        (d / ".git" / "config").write_text("[core]\n")
        (d / "src").mkdir()
        return d

    def test_a_plain_clone_is_one_gitdir_line_with_its_inode(self):
        d = self.repo("app")
        self.assertEqual(scan(self.home, "app"), [["gitdir", "app/.git", str((d / ".git").stat().st_ino)]])

    def test_a_local_only_dir_and_a_missing_dir_say_nothing(self):
        (self.home / "lab").mkdir()
        (self.home / "lab" / "CLAUDE.md").write_text("x")
        self.assertEqual(scan(self.home, "lab", "absent"), [])

    def test_a_git_file_or_symlink_at_the_top_is_refused(self):
        (self.home / "lab").mkdir()
        (self.home / "lab" / ".git").write_text("gitdir: .x\n")
        (self.home / "lnk").mkdir()
        (self.home / "lnk" / ".git").symlink_to(self.home / "elsewhere")
        rows = scan(self.home, "lab", "lnk")
        self.assertEqual([r[:2] for r in rows], [["refuse", "lab/.git"], ["refuse", "lnk/.git"]])
        self.assertIn("not a directory", rows[0][2])

    def test_submodules_are_refused_next_to_the_gitdir_line(self):
        d = self.repo("app")
        (d / ".git" / "modules" / "libs" / "foo").mkdir(parents=True)
        rows = scan(self.home, "app")
        self.assertEqual(rows[0][:2], ["gitdir", "app/.git"])
        self.assertEqual(rows[1][:2], ["refuse", "app/.git/modules"])
        self.assertIn("submodules are not supported", rows[1][2])

    def test_nested_git_entries_of_every_kind_are_reported_and_not_descended(self):
        d = self.repo("app")
        (d / "src" / "vendored" / ".git").mkdir(parents=True)
        (d / "src" / "vendored" / ".git" / "deeper" / ".git").mkdir(parents=True)  # under a hit: pruned
        (d / "src" / "ptr").mkdir()
        (d / "src" / "ptr" / ".git").write_text("gitdir: ../../.git/modules/x\n")
        (d / "src" / "lnk").mkdir()
        (d / "src" / "lnk" / ".git").symlink_to("/nowhere")
        (self.home / "lab" / "x").mkdir(parents=True)
        (self.home / "lab" / "x" / ".git").mkdir()
        (self.home / "build" / "r1" / "app").mkdir(parents=True)
        (self.home / "build" / "r1" / "app" / ".git").mkdir()
        rows = scan(self.home, "app", "lab", "build")
        nested = sorted(r[1] for r in rows if r[0] == "nested")
        self.assertEqual(nested, ["app/src/lnk/.git", "app/src/ptr/.git", "app/src/vendored/.git", "build/r1/app/.git", "lab/x/.git"])
        self.assertEqual([r[0] for r in rows if r[0] != "nested"], ["gitdir"])

    def test_glob_characters_in_names_are_not_patterns(self):
        d = self.repo("f[1]")
        (d / "src" / "a*b" / "x" / "b" / ".git").mkdir(parents=True)
        rows = scan(self.home, "f[1]")
        self.assertEqual(rows[0][:2], ["gitdir", "f[1]/.git"])
        self.assertEqual([r[1] for r in rows if r[0] == "nested"], ["f[1]/src/a*b/x/b/.git"])

    def test_a_name_with_a_control_character_is_refused_quoted(self):
        d = self.repo("app")
        (d / "src" / "a\nb" / ".git").mkdir(parents=True)
        rows = scan(self.home, "app")
        self.assertEqual(rows[1][0], "refuse")
        self.assertEqual(rows[1][2], "name contains a control character")
        self.assertNotIn("\n", rows[1][1])
        self.assertIn("app/src/a", rows[1][1])

    @unittest.skipIf(os.geteuid() == 0, "root reads everything")
    def test_an_unreadable_directory_is_a_refusal_not_an_empty_result(self):
        d = self.repo("app")
        (d / "src" / "hidden" / ".git").mkdir(parents=True)
        os.chmod(d / "src" / "hidden", 0o000)
        rows = scan(self.home, "app")
        self.assertEqual(rows[0][:2], ["gitdir", "app/.git"])
        self.assertTrue(any(r[0] == "refuse" and r[1] == "app" and r[2].startswith("unreadable:") for r in rows), rows)

    def test_usage_without_dirs_is_an_error_with_no_end_line(self):
        out = subprocess.run(["bash", str(SCAN), str(self.home)], capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 2)
        self.assertNotIn("end", out.stdout)


if __name__ == "__main__":
    unittest.main()
