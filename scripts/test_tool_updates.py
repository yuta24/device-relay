import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tool_updates import main, summarize


class ToolUpdatesTests(unittest.TestCase):
    def test_current_tools(self):
        self.assertIn("All project tools are up to date", summarize({}))

    def test_reports_requested_current_and_candidate(self):
        text = summarize(
            {"python": {"requested": "3.14.3", "current": "3.14.3", "latest": "3.15.2"}}
        )
        self.assertIn("| python | 3.14.3 | 3.14.3 | 3.15.2 |", text)

    def test_incomplete_output_is_not_a_successful_check(self):
        with self.assertRaises(KeyError):
            summarize({"python": {"latest": "3.15.2"}})

    def test_missing_current_version_is_an_error(self):
        with self.assertRaises(ValueError):
            summarize(
                {"python": {"requested": "3.14.3", "current": None, "latest": "3.15.2"}}
            )

    def test_exit_status_reports_and_actions_summary(self):
        for updates in [
            {},
            {
                "python": {
                    "requested": "3.14.3",
                    "current": "3.14.3",
                    "latest": "3.15.2",
                }
            },
        ]:
            with (
                self.subTest(updates=updates),
                tempfile.TemporaryDirectory() as directory,
            ):
                summary = Path(directory) / "actions-summary.md"
                result = subprocess.CompletedProcess([], 0, json.dumps(updates), "")
                with (
                    contextlib.chdir(directory),
                    patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
                    patch(
                        "tool_updates.subprocess.run", return_value=result
                    ) as command,
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(main(), bool(updates))
                    self.assertEqual(
                        json.loads(Path("tool-updates/updates.json").read_text()),
                        updates,
                    )
                    self.assertEqual(
                        summary.read_text(), Path("tool-updates/summary.md").read_text()
                    )
                    self.assertIn("--no-global", command.call_args.args[0])
                    self.assertTrue(command.call_args.kwargs["check"])

    def test_lookup_failure_is_not_reported_as_no_updates(self):
        with patch(
            "tool_updates.subprocess.run",
            side_effect=subprocess.CalledProcessError(1, "mise"),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                main()

    def test_zero_exit_with_unchecked_tools_fails_and_preserves_partial_results(self):
        candidate = {
            "python": {"requested": "3.14.3", "current": "3.14.3", "latest": "3.15.2"}
        }
        for updates in [{}, candidate]:
            for warning in [
                "Could not check 1 tool for updates: python@3.14.3",
                "Could not check 2 tools for updates: python@3.14.3, aqua:rhysd/actionlint@1.7.12",
            ]:
                with (
                    self.subTest(updates=updates, warning=warning),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    summary = Path(directory) / "actions-summary.md"
                    result = subprocess.CompletedProcess(
                        [], 0, json.dumps(updates), "mise WARN  " + warning + "\n"
                    )
                    with (
                        contextlib.chdir(directory),
                        patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}),
                        patch("tool_updates.subprocess.run", return_value=result),
                        contextlib.redirect_stdout(io.StringIO()),
                        contextlib.redirect_stderr(io.StringIO()),
                    ):
                        self.assertTrue(main())
                        markdown = summary.read_text()
                        self.assertIn("Update check incomplete", markdown)
                        self.assertIn(warning, markdown)
                        self.assertNotIn("All project tools are up to date", markdown)
                        self.assertEqual(
                            markdown, Path("tool-updates/summary.md").read_text()
                        )
                        self.assertEqual(
                            json.loads(Path("tool-updates/updates.json").read_text()),
                            updates,
                        )

    def test_unrelated_warning_does_not_fail_a_complete_check(self):
        result = subprocess.CompletedProcess(
            [], 0, "{}", "mise WARN  unrelated configuration notice\n"
        )
        with (
            tempfile.TemporaryDirectory() as directory,
            contextlib.chdir(directory),
            patch.dict(
                os.environ, {"GITHUB_STEP_SUMMARY": str(Path(directory) / "summary.md")}
            ),
            patch("tool_updates.subprocess.run", return_value=result),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertFalse(main())
