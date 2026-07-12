#!/usr/bin/env python3
"""Regression: ham-ctl tasks show should fail clearly when --task-id is omitted."""
import json
import os
import subprocess


def main():
    repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    build = subprocess.run(
        ["nix", "build", ".#ham-ctl", "--no-link", "--print-out-paths"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    ctl_bin = os.path.join(build.stdout.strip().splitlines()[-1], "bin", "ham-ctl")

    proc = subprocess.run(
        [ctl_bin, "--daemon-url", "http://127.0.0.1:1", "tasks", "show", "task-123", "--token", "agt_test"],
        cwd=repo_dir,
        capture_output=True,
        text=True,
        check=True,
    )
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    payload = json.loads(lines[-1])
    assert payload == {"ok": False, "message": "missing required --task-id"}, payload
    print("test_ctl_tasks_show_requires_task_id: ok")


if __name__ == "__main__":
    main()
