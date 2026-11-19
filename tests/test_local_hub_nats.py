"""Real isolated local-hub NATS lifecycle checks; requires built hub/proxy env paths."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.parse import urlparse
from urllib.request import urlopen

REPO = Path(__file__).resolve().parents[1]


class LocalHubNatsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="heimdall-local-nats-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.bins = self.root / "bin"
        self.bins.mkdir()
        for name, key in [("ham-hub", "HEIMDALL_E2E_HUB_BIN"), ("ham-dev-proxy", "HEIMDALL_E2E_PROXY_BIN")]:
            binary = os.environ.get(key)
            if not binary or not Path(binary).is_file():
                self.skipTest(key + " must name a built binary")
            (self.bins / name).symlink_to(Path(binary).resolve())
        sockets = [socket.socket() for _ in range(4)]
        try:
            for sock in sockets:
                sock.bind(("127.0.0.1", 0))
            self.ports = [sock.getsockname()[1] for sock in sockets]
        finally:
            for sock in sockets:
                sock.close()
        self.env = {**os.environ, "HEIMDALL_LOCAL_STATE_ROOT": str(self.state)}
        self.command = ["bash", str(REPO / "scripts/local-hub.sh")]
        self.start_args = ["start", "--name", "nats-test", "--bin-dir", str(self.bins), "--no-ui", "--no-seed"]
        for flag, port in zip(["--hub-port", "--proxy-port", "--ui-port", "--oidc-port"], self.ports):
            self.start_args += [flag, str(port)]
        self.instance = self.state / "hubs/nats-test"
        self.addCleanup(self.stop)

    def stop(self):
        result = subprocess.run(self.command + ["stop", "--name", "nats-test"],
                                cwd=REPO, env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def nats_address(self):
        fields = dict(line.split("=", 1) for line in (self.instance / "instance.env").read_text().splitlines())
        address = urlparse(fields["NATS_URL"])
        self.assertEqual(address.hostname, "127.0.0.1")
        return address.hostname, address.port

    def assert_nats_stopped(self):
        with self.assertRaises(ConnectionRefusedError):
            with socket.create_connection(self.nats_address(), timeout=2):
                pass
        self.assertFalse((self.instance / "run/nats.pid").exists())

    def test_healthy_start_and_stop(self):
        result = subprocess.run(self.command + self.start_args, cwd=REPO, env=self.env,
                                capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for _ in range(50):
            with urlopen("http://127.0.0.1:" + str(self.ports[0]) + "/api/v1/health", timeout=2) as reply:
                events = json.load(reply)["data"]["events"]
            if events["status"] == "ok":
                break
            time.sleep(.1)
        self.assertEqual(events, {"status": "ok", "outbox_backlog": 0})
        self.assertTrue((self.instance / "nats/store").is_dir())
        with socket.create_connection(self.nats_address(), timeout=2) as conn:
            self.assertTrue(conn.recv(1024).startswith(b"INFO "))
        self.stop()
        self.assert_nats_stopped()

    def test_failed_hub_start_cleans_nats(self):
        hub = self.bins / "ham-hub"
        hub.unlink()
        hub.write_text("#!/usr/bin/env bash\nexit 42\n")
        hub.chmod(0o700)
        result = subprocess.run(self.command + self.start_args, cwd=REPO, env=self.env,
                                capture_output=True, text=True, timeout=90)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_nats_stopped()


if __name__ == "__main__":
    unittest.main()
