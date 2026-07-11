#!/usr/bin/env python3
"""Interactive Task 18 driver.

Brings up the SAME isolated daemon + Electron UI + git project that the canonical
runner uses, then drops into a REPL so we can drive the real pi/Codex coding flow
step by step and observe coordinator behavior + daemon health live.

Once the interactive flow is proven, the exact steps are folded back into
`run_task18_canonical.py` as the automated scenario.

Usage:
    python3 tests/e2e/interactive_task18.py           # bring up + REPL
    (in REPL) help
"""
from __future__ import annotations

import argparse
import json
import time
import code
from pathlib import Path

import run_task18_canonical as R


def build_args(port: int) -> argparse.Namespace:
    ns = argparse.Namespace()
    ns.preflight = False
    ns.allow_external_blockers = False
    ns.scenario = ["coding-two-teams-real-pi"]
    ns.daemon_port = port
    ns.artifacts_dir = None
    ns.wrapper_credentials_path = ""
    ns.keep_temp = True
    return ns


class Interactive:
    def __init__(self, port: int):
        self.h = R.Harness(build_args(port))
        self.chain_id = ""
        self.coordinator_id = ""

    # --- lifecycle ---
    def bringup(self):
        h = self.h
        print("[*] preflight ...")
        blockers, details = R.preflight(h.args)
        if blockers:
            print("[!] preflight blockers:", json.dumps(blockers, indent=2))
        print("[*] prepare binaries (nix build) ...")
        h.prepare_binaries()
        print("[*] write isolated config ...")
        h.write_isolated_config()
        print(f"[*] start isolated daemon on {h.daemon_url} ...")
        h.start_daemon()
        h.register_client_and_seed_agent()
        print("[*] make git repo + project 'default' ...")
        repo = R.make_git_repo(h.temp_dir / "coding-two-teams")
        h.create_project_setup("Task18 real pi coding project", "git", repo, project_id="default")
        print("[*] seed OFFLINE coordinator record (pi@task18-e2e) ...")
        h.seed_offline_coordinator("pi@task18-e2e", "default")
        print("[*] build UI (npm run build) ...")
        h.build_ui()
        print("[*] start Electron UI ...")
        h.start_ui()
        print(f"[+] UP. daemon={h.daemon_url} data={h.data_dir}")
        print(f"[+] tmux session: task18-e2e-{h.run_id}")
        print(f"[+] artifacts: {h.out_dir}")

    def daemon_alive(self) -> bool:
        try:
            self.h.http_get("/health")
            return True
        except Exception as exc:
            print("[!] daemon health failed:", exc)
            return False

    # --- UI actions ---
    def ui(self, method, path, payload=None):
        return self.h.ui(method, path, payload or {})

    def state(self):
        return self.ui("GET", "/state")

    def create_chain(self, title="Task18 real pi coding flow", goal="Tiny README change, review, merge-ready.", kind="coding", wants_vcs=True, project_id="default"):
        steps: list[R.Step] = []
        chain = R.ui_create_chain(self.h, steps, title=title, goal=goal, kind=kind, wants_vcs=wants_vcs, project_id=project_id)
        self.chain_id = chain.get("chainId", "")
        print(f"[+] created chain {self.chain_id}")
        for s in steps:
            print("   ", "OK" if s.ok else "XX", s.name)
        return chain

    def chain_status(self):
        st, _ = self.h.ham_ctl_chain_status(self.chain_id)
        ui_chain = (((self.state() or {}).get("tasks") or {}).get("chainsById") or {}).get(self.chain_id, {})
        return {"ham_ctl": st, "ui": ui_chain.get("status")}

    def resolve_coordinator(self):
        self.coordinator_id = self.h.ham_ctl_chain_coordinator(self.chain_id)
        print("[+] coordinator id:", self.coordinator_id)
        return self.coordinator_id

    def coordinator_live(self):
        cid = self.coordinator_id or self.resolve_coordinator()
        return self.h.coordinator_liveness(cid)

    def open_chain(self):
        self.ui("POST", "/click", {"query": f'[data-debug-id="home-chain-open-btn-{self.chain_id}"]'})
        time.sleep(1)
        st = self.state() or {}
        home = st.get("home") or {}
        cv = st.get("chainView") or {}
        print("[+] surface:", home.get("surface"), "| focusedChainId:", cv.get("focusedChainId"))
        return st

    def send_coordinator(self, msg="Please coordinate the tiny README change, review, and merge-ready handoff."):
        self.ui("POST", "/type", {"query": '[data-debug-id="chain-coordinator-composer-input"]', "text": msg})
        self.ui("POST", "/click", {"query": '[data-debug-id="chain-coordinator-send-btn"]'})
        print("[+] sent coordinator message")

    def pane(self, lines=60):
        cid = self.coordinator_id or "pi@task18-e2e"
        import subprocess
        session = f"task18-e2e-{self.h.run_id}"
        out = subprocess.run(["tmux", "capture-pane", "-t", f"{session}:agent-{cid}", "-p", "-S", f"-{lines}"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout
        print(out)
        return out

    def watch(self, seconds=600, interval=10):
        """Poll chain status + daemon health + coordinator liveness."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            alive = self.daemon_alive()
            cs = self.chain_status() if alive else {}
            live = self.coordinator_live() if alive else {}
            print(f"[watch] t={int(time.time())} daemon={'up' if alive else 'DOWN'} chain={cs} coord_live={live.get('live')}")
            if not alive:
                print("[!] daemon went DOWN — stopping watch")
                return
            if cs.get("ham_ctl") in {"reviewing", "completed"}:
                print("[+] chain reached", cs.get("ham_ctl"))
                return
            time.sleep(interval)

    def close(self):
        self.h.close()


def _write_marker(it: "Interactive", path: str):
    debug_port = ""
    try:
        for line in (it.h.ui_log.read_text(encoding="utf-8", errors="ignore")).splitlines():
            if "debug_server_port=" in line:
                debug_port = line.split("debug_server_port=")[-1].strip()
    except Exception:
        pass
    data = {
        "run_id": it.h.run_id,
        "daemon_url": it.h.daemon_url,
        "data_dir": str(it.h.data_dir),
        "config": str(it.h.config_path),
        "out_dir": str(it.h.out_dir),
        "ham_ctl": it.h.ham_ctl,
        "agent_token": it.h.agent_token,
        "client_token": it.h.client_token,
        "debug_port": debug_port,
        "chain_id": it.chain_id,
        "coordinator_id": it.coordinator_id,
    }
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--daemon-port", type=int, default=49422)
    ap.add_argument("--serve", action="store_true", help="bring up, write marker, and stay alive (no REPL)")
    ap.add_argument("--marker", default="/tmp/task18_interactive.json")
    ap.add_argument("--serve-seconds", type=int, default=3600)
    args = ap.parse_args()
    it = Interactive(args.daemon_port)
    it.bringup()
    _write_marker(it, args.marker)
    if args.serve:
        print(f"[+] serving; marker at {args.marker}; alive for {args.serve_seconds}s")
        deadline = time.time() + args.serve_seconds
        try:
            while time.time() < deadline:
                if not it.daemon_alive():
                    print("[!] daemon DOWN; keeping UI up, continuing to serve for diagnostics")
                time.sleep(15)
        finally:
            it.close()
        return
    banner = (
        "\nInteractive Task18 ready. Object: it\n"
        "  it.create_chain(); it.chain_status(); it.resolve_coordinator()\n"
        "  it.coordinator_live(); it.open_chain(); it.send_coordinator()\n"
        "  it.pane(); it.watch(600); it.daemon_alive(); it.close()\n"
    )
    code.interact(banner=banner, local={"it": it, "R": R})


if __name__ == "__main__":
    main()
