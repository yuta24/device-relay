"""Best-effort, session-scoped diagnostics for the Runner smoke test."""

import datetime
import json
import re
import sys
import threading
import time
from pathlib import Path


class RunnerDiagnostics:
    markers = {
        "relay: booting simulator ": "boot_started",
        "relay: session ": "boot_completed",
        "relay: building runner ": "build_started",
        "relay: reusing ": "build_reused",
        "relay: launching runner ": "launch_started",
        "relay: runner listening;": "listening",
        "relay: runner exited with status ": "runner_exited",
        "relay: shutting down simulator ": "shutdown_started",
    }

    def __init__(self, directory, session, logs=None, clock=time.monotonic):
        self.directory = directory
        self.session = session
        self.logs = logs if logs is not None else Path.home() / ".relay/logs"
        self.clock = clock
        self.started = clock()
        self.events = []
        self.warnings = []
        self.environment = {"session": session, "python": sys.version.split()[0]}
        self.secrets = []
        self.offset = 0
        self.pending = b""
        self.lock = threading.Lock()
        self.finished = threading.Event()
        self.thread = None

    def start(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        self.mark("smoke_started")
        self.thread = threading.Thread(target=self._monitor, daemon=True)
        try:
            self.thread.start()
        except RuntimeError as error:
            self.thread = None
            self.warn(error)

    def warn(self, error):
        message = self.redact(str(error))
        if message not in self.warnings:
            self.warnings.append(message)
            print(f"Runner diagnostics warning: {message}", file=sys.stderr)

    def redact(self, text):
        for secret in self.secrets:
            if secret:
                text = text.replace(secret, "[REDACTED]")
        return re.sub(
            r"(?i)(generated token:\s*|authorization:\s*bearer\s+)\S+",
            r"\1[REDACTED]",
            text,
        )

    def _write(self, path, text):
        try:
            path.write_text(self.redact(text))
        except OSError as error:
            self.warn(error)

    def _record(self, phase):
        event = {
            "phase": phase,
            "at": datetime.datetime.now(datetime.UTC).isoformat(),
            "elapsed_seconds": round(self.clock() - self.started, 3),
        }
        self.events.append(event)
        try:
            with (self.directory / "timeline.jsonl").open("a") as stream:
                stream.write(json.dumps(event) + "\n")
        except OSError as error:
            self.warn(error)

    def _capture(self):
        path = self.directory / "start.log"
        try:
            with path.open("rb") as stream:
                stream.seek(self.offset)
                chunk = stream.read()
                self.offset = stream.tell()
        except FileNotFoundError:
            return
        except OSError as error:
            self.warn(error)
            return
        lines = (self.pending + chunk).split(b"\n")
        self.pending = lines.pop()
        for raw in lines:
            line = raw.decode("utf-8", errors="replace")
            for prefix, phase in self.markers.items():
                if line.startswith(prefix):
                    self._record(phase)
                    break

    def _monitor(self):
        while not self.finished.wait(0.25):
            try:
                with self.lock:
                    self._capture()
            except Exception as error:
                self.warn(error)
                return

    def mark(self, phase):
        with self.lock:
            self._capture()
            self._record(phase)

    def save_environment(self, **values):
        self.environment.update(values)
        self._write(
            self.directory / "environment.json",
            json.dumps(self.environment, indent=2) + "\n",
        )

    def _collect(self):
        for name in ("start.log", "stop.log", "cleanup.log"):
            path = self.directory / name
            try:
                if path.is_file() and not path.is_symlink():
                    self._write(path, path.read_text(errors="replace"))
            except OSError as error:
                self.warn(error)
        # Never glob whole state directories or copy runner.json / another session.
        for prefix in ("build", "runner"):
            try:
                paths = sorted(self.logs.glob(f"{prefix}-*-{self.session}-*.log"))
            except OSError as error:
                self.warn(error)
                continue
            for path in paths:
                try:
                    if path.is_file() and not path.is_symlink():
                        self._write(
                            self.directory / path.name,
                            path.read_text(errors="replace"),
                        )
                except OSError as error:
                    self.warn(error)

    def finish(self, error=None, *, cancelled=False):
        # Optional diagnostics must never replace the smoke test's result.
        try:
            self._finish(error, cancelled=cancelled)
        except Exception as collection_error:
            self.warn(collection_error)

    def _finish(self, error, *, cancelled):
        self.finished.set()
        if self.thread is not None:
            self.thread.join(timeout=2)
            if self.thread.is_alive():
                self.warn("timeline monitor did not stop within 2 seconds")
                return
        self.mark("smoke_finished")
        try:
            self._collect()
        except Exception as collection_error:
            self.warn(collection_error)
        times = {}
        for event in self.events:
            times.setdefault(event["phase"], event["elapsed_seconds"])
        timings = {}
        for name, start, end in (
            ("boot", "boot_started", "boot_completed"),
            ("build", "build_started", "launch_started"),
            ("readiness", "launch_started", "ready"),
            ("stop", "stop_started", "stop_completed"),
            ("cleanup", "cleanup_started", "cleanup_completed"),
        ):
            timings[name] = (
                round(times[end] - times[start], 3)
                if start in times and end in times
                else None
            )
        if "build_reused" in times and "build_started" not in times:
            timings["build"] = 0
        self._write(
            self.directory / "summary.json",
            json.dumps(
                {
                    "session": self.session,
                    "status": "cancelled"
                    if cancelled
                    else "passed"
                    if error is None
                    else "failed",
                    "error": None
                    if error is None
                    else f"{type(error).__name__}: {error}",
                    "elapsed_seconds": round(self.clock() - self.started, 3),
                    "timings_seconds": timings,
                    "build_reused": "build_reused" in times,
                    "warnings": self.warnings,
                },
                indent=2,
            )
            + "\n",
        )
