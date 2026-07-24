#!/usr/bin/env python3
"""Static guard for RTE2E-4 real Bridge launch_agent behavior."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "src" / "bridge" / "hub_runtime_client.odin"
MAIN = ROOT / "src" / "bridge" / "main.odin"
OLD_WRAPPER = ROOT / "src" / "wrapper"
OLD_CTL = ROOT / "src" / "ctl"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    client = CLIENT.read_text(encoding="utf-8")
    main_src = MAIN.read_text(encoding="utf-8")

    for marker in [
        "bridge_runtime_launch_agent :: proc",
        "bridge_bootstrap_fetch_and_materialize",
        "bridge_runtime_ensure_local_endpoint",
        "bridge_agent_token_issue(instance_id, instance_token, .Wrapper)",
        "bridge_agent_token_issue(instance_id, instance_token, .Agent)",
        "bridge_runtime_wrapper_supervisor_argv",
        "wrapper-supervisor",
        "--child-agent-token",
        "tmux.ensure_agent_window",
        "bridge_runtime_record_launch",
        "bridge_runtime_select_endpoint",
        "bridge_runtime_local_endpoint_descriptor",
        "bridge_runtime_local_endpoint_unix_started",
        "bridge_runtime_local_endpoint_loopback_started",
        "bridge_runtime_stop_agent :: proc",
        "tmux.kill_window",
        "bridge_runtime_remove_launch",
        "bridge_hub_heartbeat_json",
        "state_seq",
        "bridge_command_result_json(command_id, final_status, final_runtime)",
    ]:
        require(marker in client, f"missing real launch marker: {marker}")

    for forbidden in [
        "M4/v1 smoke runner",
        "no production wrapper supervision yet",
        'bridge_runtime_set_status(instance_id, "running", "idle")',
    ]:
        require(forbidden not in client, f"launch_agent must not keep fake/stub success marker: {forbidden}")

    require("bridge_runtime_select_endpoint(local_config)" in client and "bridge_runtime_local_endpoint_unix_started" in client and "bridge_runtime_local_endpoint_loopback_started" in client, "launch must select live endpoint per Unix-primary/loopback-fallback contract")

    old_wrapper_text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_WRAPPER.rglob("*.odin"))
    old_ctl_text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_CTL.rglob("*.odin"))
    require("bridge_runtime_launch_agent" not in old_wrapper_text, "old src/wrapper must not be migrated for RTE2E-4")
    require("wrapper-supervisor" not in old_ctl_text, "old/current src/ctl must not be migrated for RTE2E-4")

    print("PASS: bridge real launch static")


if __name__ == "__main__":
    main()
