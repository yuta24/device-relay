from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

from runner_smoke import cleanup, simulator_target


def runtime(version, available=True):
    return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-"),
            "version": version, "isAvailable": available,
            "supportedDeviceTypes": [{"identifier": "iphone", "productFamily": "iPhone"}]}


class RunnerSmokeTests(unittest.TestCase):
    def test_signals_during_acquisition_preserve_ownership_and_finish_cleanup(self):
        # Use a child interpreter so real signals never target the test runner.
        program = r'''
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from unittest.mock import Mock, patch
import runner_smoke as smoke

phase, signum = sys.argv[1], int(sys.argv[2])
previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
process = Mock(pid=123)
events = []

def command(*args, **kwargs):
    if args[1:3] == ("simctl", "create"):
        if phase == "create":
            os.kill(os.getpid(), signum)
        return subprocess.CompletedProcess(args, 0, "OWNED-UDID")
    if "runtimes" in args:
        data = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                "version": "27.2", "isAvailable": True,
                "supportedDeviceTypes": [{"identifier": "iphone", "productFamily": "iPhone"}]}]}
        return subprocess.CompletedProcess(args, 0, json.dumps(data))
    return subprocess.CompletedProcess(args, 0, "27.2" if "--show-sdk-version" in args else "/tmp/bin")

def launch(*args, **kwargs):
    os.kill(os.getpid(), signum)
    return process

def cleanup(owned, binary, session, environment, diagnostics, udid, directory):
    assert udid == "OWNED-UDID"
    assert owned is (None if phase == "create" else process)
    events.append("cleanup started")
    # A second cancellation must not abort cleanup or replace the first signal.
    os.kill(os.getpid(), signal.SIGTERM)
    os.kill(os.getpid(), signal.SIGINT)
    events.append("cleanup finished")

with tempfile.TemporaryDirectory() as directory, \
     patch.object(smoke, "ROOT", Path(directory)), \
     patch.object(smoke, "run", side_effect=command), \
     patch.object(smoke.subprocess, "Popen", side_effect=launch), \
     patch.object(smoke, "cleanup", side_effect=cleanup):
    result = smoke.main()
assert events == ["cleanup started", "cleanup finished"], events
assert all(signal.getsignal(sig) == handler for sig, handler in previous.items())
sys.exit(result)
'''
        for phase in ("create", "launch"):
            for signum in (2, 15):
                with self.subTest(phase=phase, signum=signum):
                    result = subprocess.run([sys.executable, "-c", program, phase, str(signum)],
                                            cwd=Path(__file__).parent, capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 128 + signum, result.stderr)
                    self.assertIn(f"cancelled by signal {signum}", result.stderr)

    def test_selects_latest_available_runtime_within_sdk(self):
        options = [runtime("26.9"), runtime("26.10"), runtime("27.2"), runtime("27.1", False)]
        self.assertEqual(simulator_target(options, "27.1")[1], runtime("26.10")["identifier"])

    def test_missing_compatible_runtime_fails_instead_of_skipping(self):
        with self.assertRaisesRegex(RuntimeError, "no available iPhone runtime"):
            simulator_target([runtime("27.2")], "26.6")

    def test_cleanup_deletes_only_owned_device_even_after_stop_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostics = Path(directory)
            session_directory = diagnostics / "owned-session"
            session_directory.mkdir()
            process = Mock(pid=123, poll=Mock(return_value=None))
            def command(args, **kwargs):
                if args[0] == "relay":
                    raise subprocess.TimeoutExpired(args, 90)
                return subprocess.CompletedProcess(args, 0)
            with patch("runner_smoke.subprocess.run", side_effect=command) as commands, \
                 patch("runner_smoke.group_exists", return_value=True), \
                 patch("runner_smoke.os.killpg") as kill:
                with self.assertRaises(subprocess.TimeoutExpired):
                    cleanup(process, "relay", "owned-session", {}, diagnostics, "OWNED-UDID", session_directory)
                calls = [call.args[0] for call in commands.call_args_list]
                self.assertIn(("xcrun", "simctl", "delete", "OWNED-UDID"), calls)
                kill.assert_called_once()
                self.assertEqual(process.wait.call_count, 2)
                self.assertFalse(session_directory.exists())
