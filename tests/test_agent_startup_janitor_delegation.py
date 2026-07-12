#!/usr/bin/env python3
"""Static regression check for janitor lifecycle delegation."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
JANITOR = ROOT / "src" / "daemon" / "agent_startup_janitor.odin"
TRACKER = ROOT / "src" / "daemon" / "agent_runtime_tracker.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    janitor = JANITOR.read_text(encoding="utf-8")
    janitor_lines = janitor.splitlines()
    tracker = TRACKER.read_text(encoding="utf-8")

    require("agent_runtime_tracker_apply_startup_timeout :: proc" in tracker, "tracker should own startup-timeout transition")
    require("agent_runtime_tracker_apply_heartbeat_timeout :: proc" in tracker, "tracker should own heartbeat-timeout transition")
    require("agent_runtime_tracker_apply_startup_timeout(agents[i].agent_instance_id, now)" in janitor, "janitor should delegate startup timeout to tracker")
    require("agent_runtime_tracker_apply_heartbeat_timeout(agents[i].agent_instance_id)" in janitor, "janitor should delegate heartbeat timeout to tracker")
    require("agent_lifecycle_emit(" not in janitor, "janitor should not emit lifecycle events directly")
    require(not any(line.strip().startswith("agents[i].startup_status =") for line in janitor_lines), "janitor should not mutate startup_status directly")
    require(not any(line.strip().startswith("agents[i].startup_reason_code =") for line in janitor_lines), "janitor should not mutate startup_reason_code directly")
    require(not any(line.strip().startswith("agents[i].startup_safe_diagnostic =") for line in janitor_lines), "janitor should not mutate startup_safe_diagnostic directly")
    require(not any(line.strip().startswith("agents[i].startup_updated_unix_ms =") for line in janitor_lines), "janitor should not mutate startup_updated_unix_ms directly")
    require(not any(line.strip().startswith("agents[i].connected =") for line in janitor_lines), "janitor should not mutate connected directly")
    require(not any(line.strip().startswith("agents[i].has_ws =") for line in janitor_lines), "janitor should not mutate has_ws directly")
    require(not any(line.strip().startswith("agents[i].exec_state =") for line in janitor_lines), "janitor should not mutate exec_state directly")
    require("net.close(" not in janitor, "janitor should not close sockets directly")
    require("audit_janitor_tick()" in janitor, "janitor should still run audit_janitor_tick")
    require("test_run_janitor_tick()" in janitor, "janitor should still run test_run_janitor_tick")

    print("AGENT STARTUP JANITOR DELEGATION TEST PASSED")


if __name__ == "__main__":
    main()
