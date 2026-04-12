#!/usr/bin/env python3
"""
Keep one remote-capture helper process per generated cell source definition.

This avoids relying on Kismet add_source API calls for the custom cell datasource
driver path, while still streaming phone data into Kismet via the remote capture
server.
"""

import hashlib
import os
import re
import signal
import subprocess
import sys
import time
from typing import Dict, List


SOURCE_FILE = os.environ.get("SOURCE_FILE", "/var/lib/kismet/cell/sources.generated")
REMOTE_HOSTPORT = os.environ.get("REMOTE_HOSTPORT", "127.0.0.1:3501")
HELPER_BIN = os.environ.get("HELPER_BIN", "/usr/bin/kismet_cap_cell_capture")
LOG_DIR = os.environ.get("LOG_DIR", "/var/log/kismet/cell-bridge")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "5"))


def log(msg: str) -> None:
    print(f"[cell-bridge] {msg}", flush=True)


def _safe_name(definition: str) -> str:
    name = ""
    for tok in definition.split(":")[-1].split(","):
        if tok.startswith("name="):
            name = tok.split("=", 1)[1]
            break
    if not name:
        name = "cell"
    name = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")
    if not name:
        name = "cell"
    return name


def _logfile_path(definition: str) -> str:
    digest = hashlib.sha1(definition.encode("utf-8")).hexdigest()[:10]
    return os.path.join(LOG_DIR, f"{_safe_name(definition)}-{digest}.log")


def read_definitions(path: str) -> List[str]:
    if not os.path.exists(path):
        return []

    defs: List[str] = []
    with open(path, "r", encoding="utf-8", errors="replace") as infile:
        for raw in infile:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if not line.startswith("source="):
                continue
            definition = line[len("source=") :].strip()
            if definition:
                defs.append(definition)
    # Preserve order while deduplicating.
    return list(dict.fromkeys(defs))


class ProcState:
    def __init__(self, definition: str, proc: subprocess.Popen, logfh):
        self.definition = definition
        self.proc = proc
        self.logfh = logfh


class Bridge:
    def __init__(self) -> None:
        self.procs: Dict[str, ProcState] = {}
        self.stop = False

    def terminate(self, *_args) -> None:
        self.stop = True

    def _spawn(self, definition: str) -> None:
        os.makedirs(LOG_DIR, exist_ok=True)
        logfile = _logfile_path(definition)
        logfh = open(logfile, "ab", buffering=0)
        cmd = [
            HELPER_BIN,
            "--connect",
            REMOTE_HOSTPORT,
            "--tcp",
            "--source",
            definition,
        ]
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=logfh,
            stderr=subprocess.STDOUT,
            close_fds=True,
        )
        self.procs[definition] = ProcState(definition, proc, logfh)
        log(f"started pid={proc.pid} definition='{definition}' logfile={logfile}")

    def _stop_one(self, definition: str) -> None:
        state = self.procs.pop(definition, None)
        if state is None:
            return

        proc = state.proc
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
        except Exception:
            pass

        try:
            state.logfh.close()
        except Exception:
            pass
        log(f"stopped definition='{definition}'")

    def _reconcile(self, desired: List[str]) -> None:
        desired_set = set(desired)
        current_set = set(self.procs.keys())

        for definition in sorted(current_set - desired_set):
            self._stop_one(definition)

        for definition in desired:
            state = self.procs.get(definition)
            if state is None:
                self._spawn(definition)
                continue
            if state.proc.poll() is not None:
                # Process exited; rotate and restart.
                self._stop_one(definition)
                self._spawn(definition)

    def shutdown(self) -> None:
        for definition in list(self.procs.keys()):
            self._stop_one(definition)

    def run(self) -> int:
        if not os.path.exists(HELPER_BIN):
            log(f"helper binary not found: {HELPER_BIN}")
            return 1

        signal.signal(signal.SIGTERM, self.terminate)
        signal.signal(signal.SIGINT, self.terminate)

        log(
            f"starting bridge source_file={SOURCE_FILE} remote={REMOTE_HOSTPORT} helper={HELPER_BIN}"
        )

        while not self.stop:
            try:
                desired = read_definitions(SOURCE_FILE)
                self._reconcile(desired)
            except Exception as exc:
                log(f"bridge loop error: {exc}")
            time.sleep(POLL_INTERVAL)

        self.shutdown()
        log("bridge stopped")
        return 0


def main() -> int:
    bridge = Bridge()
    return bridge.run()


if __name__ == "__main__":
    sys.exit(main())
