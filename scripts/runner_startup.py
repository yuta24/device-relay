"""Bound Runner startup phases without charging boot time against build/readiness."""

import time

RUNNER_READY_TIMEOUT = 240
STARTUP_LIMITS = {
    # simctl boot: 300s, bootstatus: 600s, plus preflight/scheduling grace.
    "boot": 960,
    "build": 600,
    "ready": RUNNER_READY_TIMEOUT + 30,
}


class StartupWatchdog:
    phases = ("boot", "build", "ready")

    def __init__(self, log, warn, *, clock=time.monotonic):
        self.log = log
        self.warn = warn
        self.clock = clock
        self.phase = "boot"
        self.started = clock()
        self.deadline = self.started + STARTUP_LIMITS[self.phase]
        self.total_deadline = self.started + sum(STARTUP_LIMITS.values())
        self.tracking = True

    def check(self):
        now = self.clock()
        if now >= self.total_deadline:
            raise TimeoutError(
                f"runner startup did not complete within {sum(STARTUP_LIMITS.values())} seconds"
            )
        if not self.tracking:
            return
        try:
            text = self.log.read_text(errors="replace")
        except OSError as error:
            # A diagnostics read failure must not become a functional failure.
            # The aggregate bound still prevents startup from waiting forever.
            self.warn(error)
            self.tracking = False
            return
        lines = text.splitlines()
        observed = (
            "ready"
            if any(line.startswith("relay: launching runner on ") for line in lines)
            else "build"
            if any(line.startswith("relay: session ") for line in lines)
            else "boot"
        )
        if self.phases.index(observed) > self.phases.index(self.phase):
            self.phase = observed
            self.deadline = now + STARTUP_LIMITS[observed]
        if now >= self.deadline:
            raise TimeoutError(
                f"runner {self.phase} phase did not complete within {STARTUP_LIMITS[self.phase]} seconds"
            )
