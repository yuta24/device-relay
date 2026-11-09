import re
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from runner_smoke import STOP_TIMEOUT
from runner_startup import STARTUP_LIMITS, StartupWatchdog


class StartupWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / "start.log"
        self.log.write_text("")
        self.now = 0
        self.warn = Mock()
        self.watchdog = StartupWatchdog(self.log, self.warn, clock=lambda: self.now)

    def progress(self, elapsed, text):
        self.now = elapsed
        self.log.write_text(text)
        self.watchdog.check()

    def test_slow_boot_and_build_do_not_consume_the_readiness_budget(self):
        self.progress(373, "relay: session owned\n")
        self.progress(601, "relay: session owned\n")
        self.assertEqual(self.watchdog.phase, "build")
        self.progress(773, "relay: session owned\nrelay: launching runner on DEVICE\n")
        self.progress(1000, "relay: launching runner on DEVICE\n")
        self.assertEqual(self.watchdog.phase, "ready")

    def test_stalled_boot_times_out_with_its_phase_name(self):
        self.now = STARTUP_LIMITS["boot"]
        with self.assertRaisesRegex(TimeoutError, "runner boot phase"):
            self.watchdog.check()

    def test_phase_completed_before_deadline_is_accepted_at_next_poll(self):
        for previous, following, marker in (
            ("boot", "build", "relay: session owned\n"),
            ("build", "ready", "relay: launching runner on DEVICE\n"),
        ):
            with self.subTest(transition=f"{previous} to {following}"):
                self.now = 0
                self.watchdog = StartupWatchdog(
                    self.log, self.warn, clock=lambda: self.now
                )
                if previous == "build":
                    self.progress(100, "relay: session owned\n")
                deadline = self.watchdog.deadline
                # The marker arrives before the deadline; the next 250ms poll
                # runs just after it. The completed phase must not time out.
                self.now = deadline - 0.1
                self.log.write_text(marker)
                self.now = deadline + 0.1
                self.watchdog.check()
                self.assertEqual(self.watchdog.phase, following)
                self.now = self.watchdog.deadline
                with self.assertRaisesRegex(TimeoutError, f"runner {following} phase"):
                    self.watchdog.check()

    def test_new_phase_marker_cannot_bypass_the_aggregate_deadline(self):
        self.progress(100, "relay: session owned\n")
        self.log.write_text("relay: launching runner on DEVICE\n")
        self.now = sum(STARTUP_LIMITS.values())
        with self.assertRaisesRegex(TimeoutError, "runner startup did not complete"):
            self.watchdog.check()

    def test_repeated_build_messages_do_not_extend_the_build_deadline(self):
        self.progress(100, "relay: session owned\n")
        self.progress(
            200, "relay: session owned\nrelay: building runner from sources\n"
        )
        self.now = 100 + STARTUP_LIMITS["build"]
        with self.assertRaisesRegex(TimeoutError, "runner build phase"):
            self.watchdog.check()

    def test_repeated_launch_messages_do_not_extend_the_ready_deadline(self):
        self.progress(100, "relay: session owned\n")
        self.progress(200, "relay: launching runner on DEVICE\n")
        self.progress(300, "relay: launching runner on DEVICE\n")
        self.now = 200 + STARTUP_LIMITS["ready"]
        with self.assertRaisesRegex(TimeoutError, "runner ready phase"):
            self.watchdog.check()

    def test_late_or_truncated_log_does_not_move_the_phase_backwards(self):
        self.progress(100, "relay: launching runner on DEVICE\n")
        self.progress(200, "relay: session owned\n")
        self.assertEqual(self.watchdog.phase, "ready")

    def test_quoted_markers_in_error_text_do_not_advance_the_phase(self):
        self.progress(100, "error: missing 'relay: launching runner on DEVICE'\n")
        self.assertEqual(self.watchdog.phase, "boot")

    def test_log_read_failure_warns_and_keeps_a_bounded_aggregate_wait(self):
        with patch.object(
            Path, "read_text", side_effect=PermissionError("unreadable log")
        ):
            self.watchdog.check()
            self.now = STARTUP_LIMITS["boot"] + 1
            self.watchdog.check()
        self.warn.assert_called_once()
        self.now = sum(STARTUP_LIMITS.values())
        with self.assertRaisesRegex(TimeoutError, "runner startup did not complete"):
            self.watchdog.check()

    def test_progress_cannot_extend_the_aggregate_startup_bound(self):
        self.progress(STARTUP_LIMITS["boot"] - 1, "relay: session owned\n")
        self.progress(
            STARTUP_LIMITS["boot"] + STARTUP_LIMITS["build"] - 2,
            "relay: launching runner on DEVICE\n",
        )
        self.now = sum(STARTUP_LIMITS.values())
        with self.assertRaisesRegex(TimeoutError, "runner startup did not complete"):
            self.watchdog.check()

    def test_ci_allows_startup_normal_stop_cleanup_and_artifact_time(self):
        workflow = (
            Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"
        ).read_text()
        job = workflow.split("\n  runner:\n", 1)[1]
        job_minutes = int(re.search(r"timeout-minutes: (\d+)", job)[1])
        step_minutes = int(
            re.search(r"run: mise run test:runner\s+timeout-minutes: (\d+)", job)[1]
        )
        # Preparation queries/create, three startup phases, ping/auth, normal stop,
        # and fallback stop/reap/shutdown/delete must fit inside the step watchdog.
        budget = 510 + sum(STARTUP_LIMITS.values()) + 135 + STOP_TIMEOUT + 30 + 5
        budget += STOP_TIMEOUT + 5 + 15 + 120 + 120
        self.assertGreater(step_minutes * 60, budget)
        self.assertGreater(job_minutes, step_minutes)
