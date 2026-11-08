"""Exercise a real Runner on a disposable iOS simulator, without touching existing devices."""

import contextlib
import fcntl
import json
import os
from pathlib import Path
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


ROOT = Path(__file__).resolve().parents[1]


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
        self.previous = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        for sig in self.previous:
            signal.signal(sig, self.receive)
        return self

    def __exit__(self, *args):
        for sig, handler in self.previous.items():
            signal.signal(sig, handler)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, timeout=120, **kwargs)


def simulator_target(runtimes, sdk):
    def version(value):
        parts = tuple(int(part) for part in value.split("."))
        return parts + (0,) * (3 - len(parts))
    candidates = [r for r in runtimes if r.get("isAvailable")
                  and ".iOS-" in r["identifier"] and version(r["version"]) <= version(sdk)]
    for runtime in sorted(candidates, key=lambda r: version(r["version"]), reverse=True):
        devices = sorted(runtime.get("supportedDeviceTypes", []),
                         key=lambda d: (not d["identifier"].endswith(".iPhone-17-Pro"), d["identifier"]))
        for device in devices:
            if device.get("productFamily") == "iPhone":
                return device["identifier"], runtime["identifier"]
    raise RuntimeError(f"no available iPhone runtime compatible with simulator SDK {sdk}")


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


def cleanup(process, binary, session, environment, diagnostics, udid, directory):
    try:
        if process is not None:
            try:
                if process.poll() is None:
                    with (diagnostics / "cleanup.log").open("w") as log:
                        subprocess.run([str(binary), "stop", "--session", session], env=environment,
                                       stdout=log, stderr=subprocess.STDOUT, timeout=90)
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
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True, timeout=60)
        finally:
            run("xcrun", "simctl", "delete", udid, capture_output=True)
            # Only this UUID-named session, after its owned processes/device are stopped.
            if directory.exists():
                shutil.rmtree(directory)


def smoke(cancellation):
    environment = dict(os.environ)
    for key in ("RELAY_RUNNER", "RELAY_SESSION", "RELAY_HOME"):
        environment.pop(key, None)
    binary = Path(run("xcrun", "swift", "build", "--show-bin-path", capture_output=True).stdout.strip()) / "relay"
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version", capture_output=True).stdout.strip()
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json", capture_output=True).stdout)["runtimes"]
    device, runtime = simulator_target(runtimes, sdk)
    session = "smoke-" + uuid.uuid4().hex
    directory = Path.home() / ".relay/sessions" / session
    info_path = directory / "runner.json"
    diagnostics = ROOT / "runner-smoke"
    diagnostics.mkdir(exist_ok=True)
    udid = None
    process = None
    try:
        # Record ownership before a pending signal can raise and enter cleanup.
        with cancellation.defer():
            udid = run("xcrun", "simctl", "create", session, device, runtime, capture_output=True).stdout.strip()
        cancellation.check()
        with (diagnostics / "start.log").open("w") as log:
            with cancellation.defer():
                process = subprocess.Popen(
                    [str(binary), "start", "--udid", udid, "--simulator", "--session", session,
                     "--project", str(ROOT), "--ready-timeout", "240"],
                    cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                )
            cancellation.check()
            deadline = time.monotonic() + 600
            while not info_path.exists():
                if process.poll() is not None:
                    raise RuntimeError("relay start exited before ready; see runner-smoke/start.log")
                if time.monotonic() >= deadline:
                    raise TimeoutError("runner did not become ready within 600 seconds")
                time.sleep(0.25)
            # runner.json is created before the write finishes, so wait for a complete JSON document.
            while True:
                try:
                    info = json.loads(info_path.read_text())
                    break
                except json.JSONDecodeError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("runner.json was not completed")
                    time.sleep(0.1)
            if info["udid"] != udid or info["pid"] != process.pid or info["session"] != session:
                raise RuntimeError("runner state does not belong to this smoke test")
            for token in (None, "invalid-smoke-token"):
                status, body = ping(info["url"], token)
                if status != 401 or body.get("ok") is not False:
                    raise RuntimeError("runner did not reject missing/invalid authentication")
            status, body = ping(info["url"], info["token"])
            if status != 200 or body.get("ok") is not True:
                raise RuntimeError("authenticated ping failed")
            run(str(binary), "ping", "--session", session, env=environment, capture_output=True)
            with (diagnostics / "stop.log").open("w") as log_stop:
                run(str(binary), "stop", "--session", session, env=environment, stdout=log_stop, stderr=subprocess.STDOUT)
            process.wait(timeout=30)
            if info_path.exists() or group_exists(process.pid):
                raise RuntimeError("runner state or launch process group remains after stop")
            with (directory / "session.lock").open() as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            address = urllib.parse.urlsplit(info["url"])
            with socket.socket() as connection:
                connection.settimeout(5)
                if connection.connect_ex((address.hostname, address.port)) == 0:
                    raise RuntimeError("runner still listens after stop")
            print("PASS: Runner startup, authentication, ping, stop, state removal and lock release")
    finally:
        # Further cancellation signals must not interrupt the owned-resource teardown.
        with cancellation.defer():
            if udid is not None:
                cleanup(process, binary, session, environment, diagnostics, udid, directory)
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
