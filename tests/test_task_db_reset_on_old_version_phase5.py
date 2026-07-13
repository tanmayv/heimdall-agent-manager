#!/usr/bin/env python3
"""Phase 5 regression: old task.db versions are reset, current version is kept."""
import os
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TASK_DB = ROOT / "src/daemon/task_db_service.odin"
DAEMON_BIN = Path(os.environ.get("HAM_DAEMON_BIN", ROOT / "result/bin/ham-daemon"))
WRAPPER_BIN = Path(os.environ.get("HAM_WRAPPER_BIN", ROOT / "result-wrapper/bin/ham-wrapper"))
HOST = "127.0.0.1"


def free_port() -> int:
    sock = socket.socket()
    sock.bind((HOST, 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def wait_health(url: str) -> None:
    for _ in range(80):
        try:
            with urllib.request.urlopen(f"{url}/health", timeout=1) as res:
                if res.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError("daemon did not become healthy")


def start_daemon(data_dir: str, log_path: Path) -> tuple[subprocess.Popen, str, object]:
    port = free_port()
    config_path = Path(data_dir) / "config.toml"
    config_path.write_text(
        f'''[daemon]\nbind_host = "{HOST}"\nport = {port}\ndata_dir = "{data_dir}"\nwrapper_bin = "{WRAPPER_BIN}"\n''',
        encoding="utf-8",
    )
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [str(DAEMON_BIN), "--config", str(config_path)],
        stdout=log_file,
        stderr=subprocess.STDOUT,
    )
    return proc, f"http://{HOST}:{port}", log_file


class TaskDbResetOnOldVersionPhase5Tests(unittest.TestCase):
    def test_source_bumps_version_and_mentions_reset(self):
        src = TASK_DB.read_text()
        self.assertIn('TASK_DB_SCHEMA_VERSION :: 7', src)
        self.assertIn('task_db_reset_old_version :: proc', src)
        self.assertIn('dropping and reinitializing', src)
        self.assertIn('no migration path for this bump', src)
        self.assertNotIn('Migrating task.db to version 7', src)
        self.assertNotIn('task_db_run_migrations()', src.split('task_db_init :: proc', 1)[1].split('task_db_create_schema :: proc', 1)[0])

    def test_old_version_resets_and_current_version_is_noop(self):
        temp_dir = tempfile.mkdtemp(prefix="heimdall-phase5-")
        try:
            tasks_dir = Path(temp_dir) / "tasks"
            tasks_dir.mkdir(parents=True, exist_ok=True)
            db_path = tasks_dir / "task.db"

            # Old-version DB should be dropped/reinitialized.
            old_conn = sqlite3.connect(db_path)
            old_conn.execute("PRAGMA user_version = 6")
            old_conn.execute("CREATE TABLE old_marker(x INTEGER)")
            old_conn.execute("INSERT INTO old_marker(x) VALUES (1)")
            old_conn.commit()
            old_conn.close()

            old_log = Path(temp_dir) / "old.log"
            proc, url, log_handle = start_daemon(temp_dir, old_log)
            try:
                wait_health(url)
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                log_handle.close()

            conn = sqlite3.connect(db_path)
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            old_marker = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='old_marker'").fetchone()
            conn.close()
            self.assertEqual(version, 7)
            self.assertIsNone(old_marker, "old-version reset should remove old_marker table")
            old_log_text = old_log.read_text(encoding="utf-8")
            self.assertIn("dropping and reinitializing", old_log_text)
            self.assertIn("no migration path for this bump", old_log_text)

            # Current-version DB should be a no-op.
            keep_conn = sqlite3.connect(db_path)
            keep_conn.execute("PRAGMA user_version = 7")
            keep_conn.execute("CREATE TABLE keep_marker(x INTEGER)")
            keep_conn.execute("INSERT INTO keep_marker(x) VALUES (1)")
            keep_conn.commit()
            keep_conn.close()

            current_log = Path(temp_dir) / "current.log"
            proc, url, log_handle = start_daemon(temp_dir, current_log)
            try:
                wait_health(url)
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                log_handle.close()

            conn = sqlite3.connect(db_path)
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            keep_marker = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='keep_marker'").fetchone()
            conn.close()
            self.assertEqual(version, 7)
            self.assertIsNotNone(keep_marker, "current-version init should not drop keep_marker table")
            current_log_text = current_log.read_text(encoding="utf-8")
            self.assertIn("already up to date; no reset needed", current_log_text)
            self.assertNotIn("dropping and reinitializing", current_log_text)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
