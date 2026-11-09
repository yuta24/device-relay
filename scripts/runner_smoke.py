"""Exercise a real Runner on a disposable iOS simulator, without touching existing devices."""

import contextlib
import fcntl
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from runner_diagnostics import RunnerDiagnostics
from runner_startup import RUNNER_READY_TIMEOUT, STARTUP_LIMITS, StartupWatchdog

ROOT = Path(__file__).resolve().parents[1]
# relay stop allows 180 seconds for the launcher, plus its own setup/cleanup.
STOP_TIMEOUT = 240
DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


class Cancelled(Exception):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"Runner smoke cancelled by signal {signum}")


class Cancellation:
    """Turn SIGINT/SIGTERM into exceptions, deferring during resource acquisition/cleanup."""

    def __init__(self):
        self.requested = None
        self.deferred = 0

    def receive(self, signum, frame):
        if self.requested is None:
            self.requested = signum
        if not self.deferred:
            self.check()

    def check(self):
        if self.requested is not None:
            raise Cancelled(self.requested)

    @contextlib.contextmanager
    def defer(self):
        self.deferred += 1
        try:
            yield
        finally:
            self.deferred -= 1

    def __enter__(self):
        self.previous = {
            sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)
        }
        for sig in self.previous:
            signal.signal(sig, self.receive)
        return self

    def __exit__(self, *args):
        for sig, handler in self.previous.items():
            signal.signal(sig, handler)


def run(*args, timeout=120, **kwargs):
    return subprocess.run(args, check=True, text=True, timeout=timeout, **kwargs)


def simulator_target(runtimes, sdk):
    def version(value):
        parts = tuple(int(part) for part in value.split("."))
        return parts + (0,) * (3 - len(parts))

    candidates = [
        r
        for r in runtimes
        if r.get("isAvailable")
        and ".iOS-" in r["identifier"]
        and version(r["version"]) <= version(sdk)
        and any(
            device["identifier"] == DEVICE_TYPE
            and device.get("productFamily") == "iPhone"
            for device in r.get("supportedDeviceTypes", [])
        )
    ]
    if candidates:
        # Resolve equal OS versions by identifier, never simctl's enumeration order.
        runtime = max(
            candidates, key=lambda r: (version(r["version"]), r["identifier"])
        )
        return DEVICE_TYPE, runtime["identifier"]
    raise RuntimeError(
        f"no available iPhone 17 Pro runtime compatible with simulator SDK {sdk}"
    )


def ping(url, token=None):
    headers = {} if token is None else {"Authorization": f"Bearer {token}"}
    request = urllib.request.Request(url + "ping", headers=headers)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=5) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        with error:
            return error.code, json.load(error)


def group_exists(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop(binary, session, environment, log, *, check=True):
    return subprocess.run(
        [str(binary), "stop", "--session", session],
        env=environment,
        stdout=log,
        stderr=subprocess.STDOUT,
        timeout=STOP_TIMEOUT,
        check=check,
        text=True,
    )


def cleanup(process, binary, session, environment, artifacts, udid, directory):
    try:
        if process is not None:
            try:
                if process.poll() is None:
                    with (artifacts / "cleanup.log").open("w") as log:
                        stop(binary, session, environment, log, check=False)
            finally:
                # Reap a stopped launcher before probing its group. On macOS a
                # group containing only an unreaped zombie can report EPERM.
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                if group_exists(process.pid):
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass  # The group exited between the probe and the signal.
                process.wait(timeout=15)
    finally:
        try:
            subprocess.run(
                ["xcrun", "simctl", "shutdown", udid], capture_output=True, timeout=120
            )
        finally:
            try:
                run("xcrun", "simctl", "delete", udid, capture_output=True)
            finally:
                # Only remove this run's UUID-named session.
                if directory.exists():
                    shutil.rmtree(directory)


def smoke(cancellation):
    session = "smoke-" + uuid.uuid4().hex
    diagnostics = RunnerDiagnostics(ROOT / "runner-smoke" / session, session)
    try:
        with cancellation.defer():
            diagnostics.start()
        cancellation.check()
        exercise(cancellation, session, diagnostics)
    finally:
        with cancellation.defer():
            error = sys.exception()
            if error is None and cancellation.requested is not None:
                error = Cancelled(cancellation.requested)
            diagnostics.finish(error, cancelled=isinstance(error, Cancelled))
    cancellation.check()


def exercise(cancellation, session, diagnostics):
    artifacts = diagnostics.directory
    diagnostics.save_environment(
        developer_dir=os.environ.get("DEVELOPER_DIR"),
        host=os.uname().sysname,
        host_release=os.uname().release,
        macos_version=platform.mac_ver()[0],
        startup_limits_seconds=STARTUP_LIMITS,
    )
    try:
        xcode = run(
            "xcodebuild", "-version", capture_output=True, timeout=30
        ).stdout.strip()
        diagnostics.save_environment(xcode=xcode)
    except (OSError, subprocess.SubprocessError) as error:
        diagnostics.warn(error)
    environment = dict(os.environ)
    for key in ("RELAY_RUNNER", "RELAY_SESSION", "RELAY_HOME"):
        environment.pop(key, None)
    binary = (
        Path(
            run(
                "xcrun", "swift", "build", "--show-bin-path", capture_output=True
            ).stdout.strip()
        )
        / "relay"
    )
    sdk = run(
        "xcrun", "--sdk", "iphonesimulator", "--show-sdk-version", capture_output=True
    ).stdout.strip()
    diagnostics.save_environment(simulator_sdk=sdk)
    runtimes = json.loads(
        run("xcrun", "simctl", "list", "runtimes", "--json", capture_output=True).stdout
    )["runtimes"]
    diagnostics.save_environment(
        runtimes=[
            {
                key: item.get(key)
                for key in ("identifier", "version", "buildversion", "isAvailable")
            }
            for item in runtimes
        ]
    )
    device, runtime = simulator_target(runtimes, sdk)
    selected = next(item for item in runtimes if item["identifier"] == runtime)
    diagnostics.save_environment(
        device_type=device,
        runtime=runtime,
        runtime_version=selected.get("version"),
        runtime_build=selected.get("buildversion"),
    )
    directory = Path.home() / ".relay/sessions" / session
    info_path = directory / "runner.json"
    udid = None
    process = None
    try:
        # Record ownership before a pending signal can raise and enter cleanup.
        with cancellation.defer():
            diagnostics.mark("simulator_create_started")
            udid = run(
                "xcrun",
                "simctl",
                "create",
                session,
                device,
                runtime,
                capture_output=True,
            ).stdout.strip()
            diagnostics.save_environment(udid=udid)
            diagnostics.mark("simulator_created")
        cancellation.check()
        with (artifacts / "start.log").open("w") as log:
            with cancellation.defer():
                diagnostics.mark("relay_started")
                process = subprocess.Popen(
                    [
                        str(binary),
                        "start",
                        "--udid",
                        udid,
                        "--simulator",
                        "--session",
                        session,
                        "--project",
                        str(ROOT),
                        "--ready-timeout",
                        str(RUNNER_READY_TIMEOUT),
                    ],
                    cwd=ROOT,
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                diagnostics.save_environment(relay_pid=process.pid)
            cancellation.check()
            startup = StartupWatchdog(artifacts / "start.log", diagnostics.warn)
            while not info_path.exists():
                if process.poll() is not None:
                    raise RuntimeError(
                        f"relay start exited before ready; see {artifacts / 'start.log'}"
                    )
                startup.check()
                time.sleep(0.25)
            # runner.json is created before the write finishes, so wait for a complete JSON document.
            while True:
                startup.check()
                try:
                    info = json.loads(info_path.read_text())
                    break
                except json.JSONDecodeError:
                    time.sleep(0.1)
            if isinstance(info.get("token"), str):
                diagnostics.secrets.append(info["token"])
            if (
                info["udid"] != udid
                or info["pid"] != process.pid
                or info["session"] != session
            ):
                raise RuntimeError("runner state does not belong to this smoke test")
            diagnostics.mark("ready")
            for token in (None, "invalid-smoke-token"):
                status, body = ping(info["url"], token)
                if status != 401 or body.get("ok") is not False:
                    raise RuntimeError(
                        "runner did not reject missing/invalid authentication"
                    )
            status, body = ping(info["url"], info["token"])
            if status != 200 or body.get("ok") is not True:
                raise RuntimeError("authenticated ping failed")
            run(
                str(binary),
                "ping",
                "--session",
                session,
                env=environment,
                capture_output=True,
            )
            diagnostics.mark("stop_started")
            with (artifacts / "stop.log").open("w") as log_stop:
                stop(binary, session, environment, log_stop)
            process.wait(timeout=30)
            diagnostics.mark("stop_completed")
            if info_path.exists() or group_exists(process.pid):
                raise RuntimeError(
                    "runner state or launch process group remains after stop"
                )
            with (directory / "session.lock").open() as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            address = urllib.parse.urlsplit(info["url"])
            with socket.socket() as connection:
                connection.settimeout(5)
                if connection.connect_ex((address.hostname, address.port)) == 0:
                    raise RuntimeError("runner still listens after stop")
            print(
                "PASS: Runner startup, authentication, ping, stop, state removal and lock release"
            )
    finally:
        # Further cancellation signals must not interrupt the owned-resource teardown.
        with cancellation.defer():
            if udid is not None:
                diagnostics.mark("cleanup_started")
                cleanup(
                    process, binary, session, environment, artifacts, udid, directory
                )
                diagnostics.mark("cleanup_completed")
    cancellation.check()


def main():
    try:
        with Cancellation() as cancellation:
            smoke(cancellation)
        return 0
    except Cancelled as error:
        print(str(error), file=sys.stderr)
        return 128 + error.signum


if __name__ == "__main__":
    sys.exit(main())
