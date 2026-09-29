"""Owned headless Photo Wagon process and its existing JSON-lines IPC protocol."""

import json
import socket
import subprocess
import time


class DemoCore:
    def __init__(self, command, work, env):
        self.command, self.work, self.env = command, work, env
        self.proc = self.sock = self.stream = self.log = None
        self.next_id = 0

    def __enter__(self):
        self.log = (self.work / "core.log").open("a")
        try:
            self.proc = subprocess.Popen(
                self.command + ["--headless", "--exit-with-parent"],
                env=self.env, stdout=self.log, stderr=subprocess.STDOUT,
            )
            port_file = self.work / "runtime" / "daemon.port"
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if self.proc.poll() is not None:
                    raise RuntimeError(f"Core exited; see {self.work / 'core.log'}")
                if port_file.exists():
                    self.port = int(port_file.read_text())
                    try:
                        self.sock = socket.create_connection(("127.0.0.1", self.port), 5)
                        break
                    except OSError:
                        pass
                time.sleep(0.1)
            else:
                raise TimeoutError("Core did not open its IPC listener")
            self.sock.settimeout(60)
            self.stream = self.sock.makefile("rb")
            self.call("daemon.hello")
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def call(self, method, params=None):
        self.next_id += 1
        request = {"id": self.next_id, "method": method, "params": params or {}}
        self.sock.sendall((json.dumps(request) + "\n").encode())
        while True:
            line = self.stream.readline()
            if not line:
                raise ConnectionError(f"Core closed IPC during {method}")
            reply = json.loads(line)
            if "event" in reply:
                continue
            if reply.get("id") != self.next_id:
                raise RuntimeError(f"Unexpected IPC reply: {reply}")
            if "error" in reply:
                raise RuntimeError(f"{method}: {reply['error']}")
            return reply["result"]

    def wait(self, method, predicate, label, timeout=240):
        deadline = time.monotonic() + timeout
        last_report = 0
        while time.monotonic() < deadline:
            result = self.call(method)
            if predicate(result):
                return result
            if time.monotonic() - last_report > 5:
                print(f"{label}: {result}", flush=True)
                last_report = time.monotonic()
            time.sleep(0.5)
        raise TimeoutError(f"Timed out: {label}; see {self.work / 'core.log'}")

    def __exit__(self, *exc):
        if self.proc and self.proc.poll() is None:
            if self.stream:
                try:
                    self.call("daemon.shutdown")
                except (OSError, RuntimeError, ValueError):
                    pass
            else:
                self.proc.terminate()
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.stream:
            self.stream.close()
        if self.sock:
            self.sock.close()
        if self.log:
            self.log.close()
