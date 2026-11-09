import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import runner_smoke
from runner_diagnostics import RunnerDiagnostics


class RunnerDiagnosticsTests(unittest.TestCase):
    def test_partial_lines_and_cached_build_have_timings_without_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [100]
            diagnostics = RunnerDiagnostics(
                root, "owned", logs=root / "logs", clock=lambda: now[0]
            )
            log = root / "start.log"
            log.write_text("relay: booting simulator owned\nrelay: sess")
            diagnostics.mark("relay_started")
            now[0] = 110
            with log.open("a") as stream:
                stream.write(
                    "ion owned\nrelay: reusing cached.xctestrun\nrelay: launching runner on DEVICE\n"
                )
            diagnostics.mark("launch_observed")
            now[0] = 120
            diagnostics.mark("ready")
            diagnostics.mark("stop_started")
            now[0] = 125
            diagnostics.mark("stop_completed")
            diagnostics.finish()
            result = json.loads((root / "summary.json").read_text())
            self.assertEqual(
                result["timings_seconds"],
                {"boot": 10, "build": 0, "readiness": 10, "stop": 5, "cleanup": None},
            )
            self.assertTrue(result["build_reused"])
            self.assertEqual(result["status"], "passed")
            events = [
                json.loads(line)
                for line in (root / "timeline.jsonl").read_text().splitlines()
            ]
            self.assertEqual(
                sum(event["phase"] == "boot_completed" for event in events), 1
            )

    def test_collects_only_owned_build_and_runner_logs_and_redacts_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            output = root / "output"
            output.mkdir()
            diagnostics = RunnerDiagnostics(output, "smoke-owned", logs=logs)
            diagnostics.secrets.append("")
            diagnostics.secrets.append("known-secret")
            (output / "start.log").write_text("Authorization: Bearer bearer-secret")
            (logs / "build-date-smoke-owned-8101.log").write_text("built known-secret")
            (logs / "runner-date-smoke-owned-8101.log").write_text(
                "generated token: generated-secret\nAuthorization: Bearer bearer-secret\nready"
            )
            (logs / "runner-date-other-session-8101.log").write_text("other session")
            (logs / "runner.json").write_text('{"token":"private-state"}')
            (logs / "runner-date-smoke-owned-8102.log").symlink_to(logs / "runner.json")
            diagnostics.finish()
            self.assertEqual(
                {p.name for p in output.glob("*.log")},
                {
                    "start.log",
                    "build-date-smoke-owned-8101.log",
                    "runner-date-smoke-owned-8101.log",
                },
            )
            contents = "\n".join(p.read_text() for p in output.iterdir())
            for secret in (
                "known-secret",
                "generated-secret",
                "bearer-secret",
                "private-state",
                "other session",
            ):
                self.assertNotIn(secret, contents)
            self.assertIn("[REDACTED]", contents)
            self.assertFalse((output / "runner.json").exists())

    def test_unfinished_phase_and_original_failure_are_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            diagnostics = RunnerDiagnostics(root, "owned", logs=root / "logs")
            diagnostics.save_environment(
                simulator_sdk="27.2", runtime="RUNTIME", device_type="DEVICE"
            )
            diagnostics.mark("launch_started")
            diagnostics.finish(TimeoutError("readiness expired"))
            result = json.loads((root / "summary.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error"], "TimeoutError: readiness expired")
            self.assertIsNone(result["timings_seconds"]["readiness"])
            self.assertEqual(
                json.loads((root / "environment.json").read_text())["runtime"],
                "RUNTIME",
            )

    def test_collection_failure_does_not_replace_success_or_failure(self):
        for failure in (None, TimeoutError("original readiness failure")):
            with (
                self.subTest(failure=failure),
                tempfile.TemporaryDirectory() as directory,
            ):
                original = Path.write_text

                def write(path, *args, **kwargs):
                    if path.name == "summary.json":
                        raise PermissionError("cannot save summary")
                    return original(path, *args, **kwargs)

                diagnostics = RunnerDiagnostics(
                    Path(directory), "owned", logs=Path(directory) / "logs"
                )
                with (
                    patch.object(Path, "write_text", write),
                    contextlib.redirect_stderr(io.StringIO()) as warnings,
                ):
                    diagnostics.finish(failure)
                self.assertIn("cannot save summary", warnings.getvalue())

    def test_smoke_preserves_failure_when_log_collection_also_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            original = TimeoutError("original smoke failure")

            def exercise(cancellation, session, diagnostics):
                diagnostics.mark("cleanup_started")
                raise original

            with (
                patch.object(runner_smoke, "ROOT", Path(directory)),
                patch.object(runner_smoke, "exercise", side_effect=exercise),
                patch.object(
                    RunnerDiagnostics,
                    "_collect",
                    side_effect=PermissionError("log access denied"),
                ),
                contextlib.redirect_stderr(io.StringIO()) as warnings,
            ):
                with self.assertRaises(TimeoutError) as caught:
                    runner_smoke.smoke(runner_smoke.Cancellation())
            self.assertIs(caught.exception, original)
            self.assertIn("log access denied", warnings.getvalue())
            self.assertTrue(list(Path(directory).glob("runner-smoke/*/timeline.jsonl")))
            result = json.loads(
                next(Path(directory).glob("runner-smoke/*/summary.json")).read_text()
            )
            self.assertEqual(result["error"], "TimeoutError: original smoke failure")

    def test_one_unreadable_log_does_not_prevent_other_logs_or_failure_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            output = root / "output"
            output.mkdir()
            (logs / "build-date-owned-8101.log").write_text("unreadable build log")
            (logs / "runner-date-owned-8101.log").write_text("runner failure details")
            read = Path.read_text

            def read_log(path, *args, **kwargs):
                if path.name.startswith("build-"):
                    raise PermissionError("build log access denied")
                return read(path, *args, **kwargs)

            diagnostics = RunnerDiagnostics(output, "owned", logs=logs)
            with (
                patch.object(Path, "read_text", read_log),
                contextlib.redirect_stderr(io.StringIO()),
            ):
                diagnostics.finish(TimeoutError("original failure"))
            self.assertEqual(
                (output / "runner-date-owned-8101.log").read_text(),
                "runner failure details",
            )
            result = json.loads((output / "summary.json").read_text())
            self.assertEqual(result["error"], "TimeoutError: original failure")
            self.assertIn("build log access denied", result["warnings"])

    def test_cancellation_summary_and_logs_are_kept_after_session_removal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            logs.mkdir()
            session_state = root / "session"
            session_state.mkdir()
            (session_state / "runner.json").write_text('{"token":"private"}')
            output = root / "output"
            diagnostics = RunnerDiagnostics(output, "owned", logs=logs)
            diagnostics.start()
            try:
                (logs / "runner-date-owned-8101.log").write_text("shutdown completed")
                (session_state / "runner.json").unlink()
                session_state.rmdir()
            finally:
                diagnostics.finish(runner_smoke.Cancelled(15), cancelled=True)
            self.assertEqual(
                json.loads((output / "summary.json").read_text())["status"], "cancelled"
            )
            self.assertEqual(
                (output / "runner-date-owned-8101.log").read_text(),
                "shutdown completed",
            )


if __name__ == "__main__":
    unittest.main()
