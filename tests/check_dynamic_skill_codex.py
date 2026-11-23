#!/usr/bin/env python3
"""Check exact bridge regression output with PyYAML and real Codex skills/list.

First run test_dynamic_skill_bootstrap_sealed_cache_restart with
HEIMDALL_SKILLFIX_EXPORT_DIR=<fixture-dir>, then run this script with that path.
No model requests or bot restarts are involved.
"""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading

import yaml


def enumerate_skills(root):
    # An isolated Codex home avoids existing account/config/plugin state.
    with tempfile.TemporaryDirectory(prefix="skillfix-codex-", dir=root) as home:
        env = dict(os.environ, CODEX_HOME=home)
        with subprocess.Popen(
            ["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, cwd=root, env=env,
        ) as process:
            messages = queue.Queue()

            def read():
                for line in process.stdout:
                    try:
                        messages.put(json.loads(line))
                    except ValueError:
                        pass
                messages.put(None)

            threading.Thread(target=read, daemon=True).start()

            def request(request_id, method, params):
                process.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
                process.stdin.flush()
                while True:
                    message = messages.get(timeout=30)
                    assert message is not None, "Codex exited before responding"
                    if message.get("id") == request_id:
                        assert "error" not in message, message
                        return message["result"]

            try:
                request(1, "initialize", {"clientInfo": {"name": "skillfix-regression", "version": "1"}})
                process.stdin.write('{"method":"initialized","params":{}}\n')
                process.stdin.flush()
                # Both a forced scan and the warm loader cache must find them.
                cold = request(2, "skills/list", {"cwds": [str(root)], "forceReload": True})
                warm = request(3, "skills/list", {"cwds": [str(root)], "forceReload": False})
                return cold, warm
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def main():
    root = Path(sys.argv[1]).resolve()
    expected = json.loads((root / "expected.json").read_text())
    names = {"mem-18eab58c00000001", "mem-18eab58c00000002"}
    paths = {}
    for path in root.glob(".*/skills/mem-*/SKILL.md"):
        text = path.read_text()
        _, frontmatter, body = text.split("---", 2)
        metadata = yaml.safe_load(frontmatter)
        name = metadata["name"]
        assert name == path.parent.name and len(name) == 20, (name, path)
        description = expected["description"] if name.endswith("1") else expected["title"]
        assert metadata["description"] == description, repr(metadata)
        assert body.endswith(expected["body"]), repr(body)
        paths[name] = path
    assert set(paths) == names, paths
    for run in range(2):  # a new real Codex process also covers loader restart
        cold, warm = enumerate_skills(root)
        for label, response in (("cold", cold), ("warm", warm)):
            entries = response["data"]
            skills = {skill["name"]: skill for entry in entries for skill in entry["skills"]}
            errors = [error for entry in entries for error in entry["errors"]]
            assert not [e for e in errors if "mem-18eab58c" in e["path"]], errors
            assert names <= skills.keys(), {"missing": sorted(names - skills.keys()), "response": response}
            for name in names:
                assert Path(skills[name]["path"]).resolve() == paths[name]
                assert skills[name]["enabled"], skills[name]
            print(f"PASS: Codex process {run + 1} {label} discovers both dynamic skills")
    print("PASS: exact YAML description/body, unique stable names/paths, real Codex cold/warm/restart")


if __name__ == "__main__":
    main()
