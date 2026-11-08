import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tool_updates import main, summarize


class ToolUpdatesTests(unittest.TestCase):
    def test_current_tools(self):
        self.assertIn("All project tools are up to date", summarize({}))

    def test_reports_requested_current_and_candidate(self):
        text = summarize({"python": {"requested": "3.14.3", "current": "3.14.3", "latest": "3.15.2"}})
        self.assertIn("| python | 3.14.3 | 3.14.3 | 3.15.2 |", text)

    def test_incomplete_output_is_not_a_successful_check(self):
        with self.assertRaises(KeyError):
            summarize({"python": {"latest": "3.15.2"}})

    def test_missing_current_version_is_an_error(self):
        with self.assertRaises(ValueError):
            summarize({"python": {"requested": "3.14.3", "current": None, "latest": "3.15.2"}})

    def test_exit_status_reports_and_actions_summary(self):
        for updates in [{}, {"python": {"requested": "3.14.3", "current": "3.14.3", "latest": "3.15.2"}}]:
            with self.subTest(updates=updates), tempfile.TemporaryDirectory() as directory:
                summary = Path(directory) / "actions-summary.md"
                result = subprocess.CompletedProcess([], 0, json.dumps(updates), "")
                with contextlib.chdir(directory), patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}), \
                     patch("tool_updates.subprocess.run", return_value=result) as command, \
                     contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(main(), bool(updates))
                    self.assertEqual(json.loads(Path("tool-updates/updates.json").read_text()), updates)
                    self.assertEqual(summary.read_text(), Path("tool-updates/summary.md").read_text())
                    self.assertIn("--no-global", command.call_args.args[0])
                    self.assertTrue(command.call_args.kwargs["check"])

    def test_lookup_failure_is_not_reported_as_no_updates(self):
        with patch("tool_updates.subprocess.run", side_effect=subprocess.CalledProcessError(1, "mise")):
            with self.assertRaises(subprocess.CalledProcessError):
                main()
