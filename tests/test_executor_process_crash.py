"""POSIX process-crash checks for the isolated executor ledger (no provider claims)."""
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import unittest

PROBE = os.environ.get("HEIMDALL_EXECUTOR_CRASH_PROBE")
@unittest.skipUnless(PROBE and os.name == "posix", "requires built probe and POSIX SIGKILL")
class ExecutorProcessCrash(unittest.TestCase):
    def test_committed_boundaries_survive_sigkill_without_reissuing_launch(self):
        cache = Path.home() / ".cache" / "heimdall-tests"
        cache.mkdir(parents=True, exist_ok=True)
        for stage in ("issuance", "prepare", "activate", "launch"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory(prefix="executor-crash-", dir=cache) as directory:
                path = str(Path(directory) / "executor.sqlite")
                child = subprocess.Popen([PROBE, "seed", path, stage], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    with selectors.DefaultSelector() as ready:
                        ready.register(child.stdout, selectors.EVENT_READ)
                        self.assertTrue(ready.select(timeout=15), "probe did not reach committed boundary")
                    marker = child.stdout.readline()
                    self.assertEqual(marker.strip(), "COMMITTED " + stage)
                    child.kill()
                    _, error = child.communicate(timeout=5)
                    self.assertEqual(child.returncode, -signal.SIGKILL, error)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate(timeout=5)
                result = subprocess.run([PROBE, "verify", path, stage], capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS " + stage, result.stdout)
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

if __name__ == "__main__":
    unittest.main()
