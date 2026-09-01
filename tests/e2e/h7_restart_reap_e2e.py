#!/usr/bin/env python3
"""H7 live restart-reap E2E: prove that RESTARTING an agent instance reaps the
OLD ham-wrapper runtime process, leaving exactly ONE wrapper for the instance.

Mechanism under test (token-invalidation self-termination, bridge-only,
cross-bridge safe):
  - On (re)launch the bridge invalidates the instance's PRIOR local tokens
    (bridge_agent_token_invalidate_instance) BEFORE issuing fresh non-deterministic
    ones.
  - The old ham-wrapper's next wrapper.liveness.ping is answered by the bridge with
    an auth failure ("unauthenticated"); the wrapper reads that response, KILLS its
    child mock agent, and exits.

This boots an ISOLATED hub+bridge (mock agent, never a real LLM, never mundus),
launches one instance, records the PID of the ham-wrapper, then calls
agent.instances.restart and asserts:
  (1) a NEW ham-wrapper PID appears for the instance, and
  (2) the OLD ham-wrapper PID is GONE within a grace period.

All logs are written under a run dir the caller can inspect (printed at the end).

Usage:
  python3 tests/e2e/h7_restart_reap_e2e.py            # uses ./result-* binaries
  HAM_HUB_BIN=... HAM_BRIDGE_BIN=... HAM_CTL_BIN=... HAM_WRAPPER_BIN=... \
      python3 tests/e2e/h7_restart_reap_e2e.py

Requires: tmux (the wrapper launches the mock agent in a tmux pane).
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MOCK = ROOT / "tools" / "mock_agent" / "mock-agent.sh"
MIGRATIONS = str(ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations")

HUB_BIN = Path(os.environ.get("HAM_HUB_BIN", ROOT / "result-hub" / "bin" / "ham-hub"))
BRIDGE_BIN = Path(os.environ.get("HAM_BRIDGE_BIN", ROOT / "result-bridge" / "bin" / "ham-bridge"))
CTL_BIN = Path(os.environ.get("HAM_CTL_BIN", ROOT / "result-ctl" / "bin" / "ham-ctl"))
WRAPPER_BIN = Path(os.environ.get("HAM_WRAPPER_BIN", ROOT / "result-wrapper" / "bin" / "ham-wrapper"))

RUN_DIR = Path(os.environ.get("H7_RUN_DIR", "/tmp/h7-restart-reap"))


def log(msg: str) -> None:
    print(f"[h7] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[h7] FAIL: {msg}", flush=True)
    sys.exit(1)


def free_port() -> int:
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def req(method: str, url: str, body=None, headers=None):
    data = None
    if body is not None:
        data = json.dumps(body).encode()
    hdrs = {"Content-Type": "application/json"}
    if headers:
        hdrs.update(headers)
    r = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}
    except Exception as e:
        return 0, {"error": str(e)}


def wrapper_pids_for(instance_id: str) -> list[int]:
    """Return PIDs of the REAL ham-wrapper bridge-runtime processes for this
    instance. We must count ONLY the actual ham-wrapper executable (argv[0] is the
    ham-wrapper binary), NOT the `/bin/zsh -l -c "... ham-wrapper ..."` login shell
    the tmux pane uses to launch it — that shell's argument string contains the
    full ham-wrapper command and would otherwise be miscounted as a second wrapper.
    """
    out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True)
    pids = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            pid_str, cmd = line.split(None, 1)
            pid = int(pid_str)
        except ValueError:
            continue
        if "bridge-runtime" not in cmd or instance_id not in cmd:
            continue
        # argv[0] must be the ham-wrapper binary (skip the login-shell wrapper,
        # whose argv[0] is a shell and whose args merely mention ham-wrapper).
        argv0 = cmd.split(None, 1)[0].strip("'\"")
        base = os.path.basename(argv0)
        if base != "ham-wrapper":
            continue
        pids.append(pid)
    return pids


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class Stack:
    def __init__(self):
        self.hub = None
        self.bridge = None

    def cleanup(self):
        for p in (self.bridge, self.hub):
            if p and p.poll() is None:
                try:
                    p.send_signal(signal.SIGINT)
                    p.wait(timeout=5)
                except Exception:
                    try:
                        p.kill()
                    except Exception:
                        pass


def main() -> None:
    for b in (HUB_BIN, BRIDGE_BIN, CTL_BIN, WRAPPER_BIN):
        if not Path(b).exists():
            die(f"missing binary: {b} (build with scripts/dev-stack.sh build or nix build)")
    if shutil.which("tmux") is None:
        die("tmux is required (the wrapper launches the mock agent in a tmux pane)")

    if RUN_DIR.exists():
        shutil.rmtree(RUN_DIR, ignore_errors=True)
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    local_dir = RUN_DIR / "local"
    local_dir.mkdir(parents=True, exist_ok=True)
    db = RUN_DIR / "hub.db"
    hub_log = open(RUN_DIR / "hub.log", "w")
    bridge_log = open(RUN_DIR / "bridge.log", "w")

    port = free_port()
    base = f"http://127.0.0.1:{port}/api/v1"
    stack = Stack()
    try:
        # --- hub ---
        stack.hub = subprocess.Popen(
            [str(HUB_BIN), "--listen", f"127.0.0.1:{port}", "--db", str(db),
             "--migrations-dir", MIGRATIONS],
            cwd=ROOT, stdout=hub_log, stderr=subprocess.STDOUT, text=True,
            env={**os.environ},
        )
        # wait for health
        ok = False
        for _ in range(120):
            time.sleep(0.25)
            st, _ = req("GET", f"{base}/health")
            if st == 200:
                ok = True
                break
        if not ok:
            die("hub did not become healthy")
        log("hub healthy")

        # --- operator user ---
        out = subprocess.run(
            [str(HUB_BIN), "users", "create", "--name", "Op", "--email", "op@example.com",
             "--db", str(db), "--migrations-dir", MIGRATIONS],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
        )
        if out.returncode != 0:
            die(f"users create failed: {out.stdout} {out.stderr}")
        kv = {}
        for line in out.stdout.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
        token = kv.get("token", "")
        if not token.startswith("hut_"):
            die(f"bad user token: {token}")
        auth = {"Authorization": f"Bearer {token}"}

        # --- bridge enrollment ---
        st, enr = req("POST", base + "/bridge-enrollments",
                      {"label": "h7", "expires_in_seconds": 3600}, auth)
        if st != 201:
            die(f"enrollment create failed: {st} {enr}")
        etok = enr["data"]["enrollment_token"]
        st, br = req("POST", base + "/bridges/enroll",
                     {"hostname": "h7-bridge", "hub_url": f"http://127.0.0.1:{port}",
                      "capabilities": [{"provider": "claude", "tiers": ["normal"],
                                        "default_tier": "normal"}]},
                     {"Authorization": f"Bearer {etok}"})
        if st != 201:
            die(f"bridge enroll failed: {st} {br}")
        bridge_id = br["data"]["bridge_id"]
        bridge_token = br["data"]["bridge_token"]

        # --- agent + bridge support ---
        st, ag = req("POST", base + "/agents",
                     {"name": "H7 Agent", "slug": "h7",
                      "default_provider": "claude", "default_tier": "normal"}, auth)
        if st != 201:
            die(f"agent create failed: {st} {ag}")
        agent_id = ag["data"]["agent_id"]
        st, _ = req("PUT", f"{base}/agents/{agent_id}/bridge-support",
                    [{"bridge_id": bridge_id, "enabled": True,
                      "provider": "claude", "tier": "normal"}], auth)
        if st != 200:
            die(f"bridge-support enable failed: {st}")

        # --- bridge with mock agent (idles forever: no replay file) ---
        replay_path = RUN_DIR / "replay.txt"  # intentionally absent -> mock idles
        mock_cmd = (f"HEIMDALL_MOCK_LOG={RUN_DIR / 'mock.log'} "
                    f"HEIMDALL_MOCK_REPLAY={replay_path} "
                    f"HAM_CTL={CTL_BIN} sh {MOCK}")
        # Isolated, minimal config so the bridge does NOT read the shared
        # ~/.config/heimdall/config.toml (which pins the dev-stack's default port
        # 49323 and deprecated keys). Bind our own free ports.
        bridge_port = free_port()
        bridge_cfg = RUN_DIR / "bridge-config.toml"
        bridge_cfg.write_text(
            f'daemon_url = "http://127.0.0.1:{port}"\n'
            f'bridge_token = "{bridge_token}"\n'
            f'daemon_id = "{bridge_id}"\n'
        )
        stack.bridge = subprocess.Popen(
            [str(BRIDGE_BIN), "--config", str(bridge_cfg),
             "--hub", f"http://127.0.0.1:{port}",
             "--bridge-token", bridge_token, "--daemon-id", bridge_id,
             "--port", str(bridge_port),
             "--agent-command", mock_cmd, "--local-run-dir", str(local_dir),
             "--local-endpoint-port", str(free_port())],
            cwd=ROOT, stdout=bridge_log, stderr=subprocess.STDOUT, text=True,
            env={**os.environ, "HEIMDALL_HAM_WRAPPER_BIN": str(WRAPPER_BIN)},
        )
        time.sleep(1.5)

        # --- launch an instance (retry until bridge online) ---
        instance_id = None
        for _ in range(150):
            time.sleep(0.25)
            st, inst_try = req("POST", base + "/agent-instances",
                               {"agent_id": agent_id, "bridge_id": bridge_id,
                                "provider": "claude", "tier": "normal"}, auth)
            if st in (200, 201):
                instance_id = inst_try["data"]["agent_instance_id"]
                break
        if not instance_id:
            die(f"bridge never came online / launch failed: {st} {inst_try}")
        log(f"launched instance {instance_id}")

        # --- wait for the FIRST ham-wrapper to appear ---
        first_pids = []
        for _ in range(120):
            time.sleep(0.5)
            first_pids = wrapper_pids_for(instance_id)
            if first_pids:
                break
        if not first_pids:
            die("no ham-wrapper process appeared for the launched instance")
        old_pid = first_pids[0]
        log(f"initial ham-wrapper PID(s): {first_pids}")
        if len(first_pids) != 1:
            log(f"WARNING: expected exactly 1 wrapper at launch, saw {first_pids}")

        # --- RESTART the instance (this is the reap trigger) ---
        st, rr = req("POST", f"{base}/agent-instances/{instance_id}/restart", {}, auth)
        if st not in (200, 201, 202):
            die(f"restart call failed: {st} {rr}")
        log(f"restart requested (hub returned {st}); waiting for reap...")

        # --- assert: NEW wrapper appears, OLD wrapper gone ---
        new_pid = None
        old_gone = False
        deadline = time.time() + 60
        while time.time() < deadline:
            time.sleep(0.5)
            pids = wrapper_pids_for(instance_id)
            live_new = [p for p in pids if p != old_pid]
            if live_new:
                new_pid = live_new[0]
            old_gone = not pid_alive(old_pid)
            if new_pid is not None and old_gone:
                break

        final_pids = wrapper_pids_for(instance_id)
        log(f"post-restart ham-wrapper PID(s): {final_pids}; old={old_pid} gone={old_gone} new={new_pid}")

        if new_pid is None:
            die("no NEW ham-wrapper appeared after restart")
        if not old_gone:
            die(f"OLD ham-wrapper PID {old_pid} is STILL ALIVE after restart (reap failed)")
        # Exactly one wrapper should remain for the instance.
        remaining = [p for p in final_pids if pid_alive(p)]
        if len(remaining) != 1:
            die(f"expected EXACTLY ONE ham-wrapper after restart, saw {remaining}")

        log("PASS: restart reaped the old runtime; exactly one ham-wrapper remains")
        log(f"  old_pid={old_pid} (gone)  new_pid={new_pid} (alive)")
        log(f"logs: hub={RUN_DIR/'hub.log'} bridge={RUN_DIR/'bridge.log'} run_dir={local_dir}")
    finally:
        stack.cleanup()
        hub_log.close()
        bridge_log.close()


if __name__ == "__main__":
    main()
