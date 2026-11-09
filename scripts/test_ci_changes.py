import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("ci-changes.sh")


def classify(paths):
    result = subprocess.run(
        ["bash", str(SCRIPT)],
        input=b"\0".join(path.encode() for path in paths) + (b"\0" if paths else b""),
        capture_output=True,
        check=True,
    )
    return dict(line.split("=") for line in result.stdout.decode().splitlines())


class CIChangesTests(unittest.TestCase):
    def test_readme_and_docs_only_skip_heavy_checks(self):
        self.assertEqual(
            classify(
                [
                    "README.md",
                    "README.ja.md",
                    "CHANGELOG.md",
                    "docs/setup.md",
                    "docs/images/example.png",
                ]
            ),
            {"code": "false", "run": "false"},
        )

    def test_product_build_and_workflow_inputs_keep_checks_enabled(self):
        for path in (
            "Sources/Relay/main.swift",
            "Runner/RelayRunner.xcodeproj/project.pbxproj",
            "skills/device-relay/SKILL.md",
            "scripts/ci-changes.sh",
            "Package.swift",
            "Makefile",
            "mise.toml",
            "mise.lock",
            ".github/workflows/ci.yml",
            ".github/workflows/release.yml",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    classify(["docs/setup.md", path]), {"code": "true", "run": "true"}
                )

    def test_other_inputs_still_run_code_checks(self):
        for path in (
            "Tests/RelayTests/Test.swift",
            "ruff.toml",
            ".editorconfig",
            ".swiftformat",
            "unknown-file",
        ):
            with self.subTest(path=path):
                self.assertEqual(classify([path]), {"code": "true", "run": "false"})

    def test_empty_diff_conservatively_runs_all_checks(self):
        self.assertEqual(classify([]), {"code": "true", "run": "true"})

    def test_null_delimiters_preserve_spaces_and_newlines_in_names(self):
        self.assertEqual(
            classify(["docs/with spaces\nand newline.md"]),
            {"code": "false", "run": "false"},
        )
        self.assertEqual(
            classify(["README.md\nnot-a-readme"]), {"code": "true", "run": "false"}
        )

    def test_unterminated_last_path_is_not_silently_ignored(self):
        result = subprocess.run(
            ["bash", str(SCRIPT)],
            input=b"README.md\0Sources/file.swift",
            capture_output=True,
            check=True,
        )
        self.assertIn(b"code=true", result.stdout)
        self.assertIn(b"run=true", result.stdout)


class CIChangesGitTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "-q", "-b", "main")
        self.write("README.md", "readme\n")
        self.write("docs/guide.md", "guide\n")
        self.write("Sources/file.swift", "source\n")
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(
            [
                "git",
                "-c",
                "user.name=CI tests",
                "-c",
                "user.email=ci@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                *args,
            ],
            cwd=self.root,
            text=True,
        ).strip()

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def commit(self):
        self.git("add", ".")
        self.git(
            "commit",
            "-qm",
            "fixture change\n\nCo-authored-by: Codex <noreply@openai.com>",
        )
        return self.git("rev-parse", "HEAD")

    def classify(self, base, head):
        result = subprocess.run(
            ["bash", str(SCRIPT), base, head],
            cwd=self.root,
            text=True,
            capture_output=True,
            check=True,
        )
        return dict(line.split("=") for line in result.stdout.splitlines())

    def test_docs_commit_after_code_changes_does_not_skip_the_pr(self):
        self.write("Sources/file.swift", "changed source\n")
        self.commit()
        self.write("README.md", "updated documentation\n")
        head = self.commit()
        self.assertEqual(
            self.classify(self.base, head), {"code": "true", "run": "true"}
        )

    def test_upstream_code_changes_are_not_attributed_to_a_docs_pr(self):
        self.git("switch", "-q", "-c", "documentation")
        self.write("README.md", "updated documentation\n")
        head = self.commit()
        self.git("switch", "-q", "main")
        self.write("Sources/upstream.swift", "upstream change\n")
        upstream = self.commit()
        self.assertEqual(
            self.classify(upstream, head), {"code": "false", "run": "false"}
        )

    def test_renaming_code_into_docs_still_runs_code_checks(self):
        (self.root / "Sources/file.swift").rename(self.root / "docs/file.md")
        head = self.commit()
        self.assertEqual(
            self.classify(self.base, head), {"code": "true", "run": "true"}
        )

    def test_deleting_code_still_runs_code_checks(self):
        (self.root / "Sources/file.swift").unlink()
        head = self.commit()
        self.assertEqual(
            self.classify(self.base, head), {"code": "true", "run": "true"}
        )

    def test_invalid_refs_fail_without_outputs_that_could_skip_checks(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "missing-ref", self.base],
            cwd=self.root,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
