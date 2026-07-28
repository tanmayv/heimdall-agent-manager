#!/usr/bin/env python3
"""Static guard for RTE2E-4 real Bridge launch_agent behavior."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "src" / "bridge" / "hub_runtime_client.odin"
MAIN = ROOT / "src" / "bridge" / "main.odin"
BOOTSTRAP = ROOT / "src" / "bridge" / "bootstrap_service.odin"
PROVIDER_STORE = ROOT / "src" / "bridge" / "provider_store.odin"
OLD_WRAPPER = ROOT / "src" / "wrapper"
OLD_CTL = ROOT / "src" / "ctl"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    client = CLIENT.read_text(encoding="utf-8")
    main_src = MAIN.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    provider_store = PROVIDER_STORE.read_text(encoding="utf-8")

    for marker in [
        "bridge_runtime_launch_agent :: proc",
        "bridge_bootstrap_fetch_and_materialize",
        "bridge_runtime_ensure_local_endpoint",
        "bridge_agent_token_issue(instance_id, instance_token, .Wrapper)",
        "bridge_agent_token_issue(instance_id, instance_token, .Agent)",
        "bridge_runtime_ham_wrapper_argv",
        "bridge-runtime",
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

    for marker in [
        "bridge_runtime_resolve_provider_executable",
        "bridge_runtime_find_on_path(trimmed)",
        "skill_dir = bridge_provider_skill_dir_from_config(cmd)",
        "bridge_provider_default_skill_dir",
        'case "pi":',
        'return ".pi/skills"',
        'case "antigravity", "agy":',
        'return ".agents/skills"',
    ]:
        require(marker in provider_store, f"missing provider store marker: {marker}")

    for marker in [
        "cfg.ham_ctl_bin = loaded.config.wrapper.ham_ctl_bin",
        "--ham-ctl-bin",
        "wrapper-supervisor is removed; use ham-wrapper bridge-runtime",
    ]:
        require(marker in main_src, f"missing Bridge config marker: {marker}")

    for marker in [
        "if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false",
        "bridge_config.ham_ctl_bin",
        "bridge bootstrap failed: ham-ctl not found",
        "if skill_dir == \"\" do skill_dir = bridge_provider_default_skill_dir(provider)",
    ]:
        require(marker in bootstrap, f"missing bootstrap marker: {marker}")

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
