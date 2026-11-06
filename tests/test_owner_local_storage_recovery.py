#!/usr/bin/env python3
"""Run against an Odin-built probe inside nix develop (rootless Nix binaries).

    odin build tests/helpers/owner_local_storage_probe -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/owner-storage-probe
    python3 tests/test_owner_local_storage_recovery.py --probe "$HOME/.cache/heimdall-tests/owner-storage-probe"
"""
import argparse
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import tempfile


def run(probe, mode, path):
    result = subprocess.run([probe, mode, str(path)], capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, (mode, result.returncode, result.stdout, result.stderr)
    return result.stdout.strip()


def kill_at(probe, mode, path, marker):
    process = subprocess.Popen([probe, mode, str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        readable, _, _ = select.select([process.stdout], [], [], 10)
        assert readable, f"probe never reached {marker}"
        actual = process.stdout.readline().decode().strip()
        assert actual == marker, (mode, actual)
        process.kill()  # actual SIGKILL: no Store.close, defers or SQLite shutdown
        _, stderr = process.communicate(timeout=5)
        assert process.returncode == -9, (process.returncode, stderr.decode())
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)


def snapshot(path):
    with sqlite3.connect(path) as db:
        assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []
        return (
            db.execute("SELECT commit_seq FROM runtime_database").fetchone()[0],
            db.execute("SELECT count(*) FROM tasks").fetchone()[0],
            db.execute("SELECT count(*) FROM command_receipts").fetchone()[0],
            db.execute("SELECT count(*) FROM local_changes").fetchone()[0],
            db.execute("SELECT count(*) FROM runtime_intents").fetchone()[0],
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True)
    args = parser.parse_args()
    cache = Path(os.environ["HOME"]) / ".cache/heimdall-tests"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="owner-storage-recovery-", dir=cache) as directory:
        path = Path(directory) / "runtime.sqlite"
        run(args.probe, "seed", path)
        assert snapshot(path) == (1, 0, 1, 1, 1)
        kill_at(args.probe, "before", path, "before_commit")
        assert snapshot(path) == (1, 0, 1, 1, 1), "kill before commit leaves no partial state"
        kill_at(args.probe, "after", path, "after_commit")
        assert snapshot(path) == (2, 1, 2, 2, 2), "lost reply retains complete committed state"
        replay = json.loads(run(args.probe, "retry", path))
        assert replay["code"] == "ok" and replay["replay"] is True and replay["seq"] == 2, replay
        assert snapshot(path) == (2, 1, 2, 2, 2), "retry never duplicates committed effects"
        with sqlite3.connect(path) as db:
            before = db.execute("SELECT intent_id,payload_digest FROM runtime_intents ORDER BY intent_id").fetchall()
        kill_at(args.probe, "claim_kill", path, "after_claim")
        run(args.probe, "settle", path)
        with sqlite3.connect(path) as db:
            after = db.execute("SELECT intent_id,payload_digest FROM runtime_intents ORDER BY intent_id").fetchall()
            assert after == before, "recovery preserves exact effect identity"
            assert db.execute("SELECT state,attempts FROM runtime_intents").fetchall() == [("settled", 2)] * 2
        assert snapshot(path) == (2, 1, 2, 2, 2)
    print("PASS: SIGKILL before commit, after commit/lost reply, and after outbox claim; replay and recovery preserve exact effects")


if __name__ == "__main__":
    main()
