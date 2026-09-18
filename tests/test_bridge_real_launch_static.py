#!/usr/bin/env python3
"""Static guard for the Bridge pty-host agent-launch contract (BR-2 / DEL-1).

The wrapper+tmux launch path was removed: the Bridge now materializes the run
dir itself and spawns/stops agents through the ham-pty-host daemon (no
ham-wrapper argv, no tmux windows). This guard locks that shipped behavior in
src/bridge and asserts the old wrapper launch path was not migrated into
src/ctl.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "src" / "bridge" / "hub_runtime_client.odin"
MAIN = ROOT / "src" / "bridge" / "main.odin"
BOOTSTRAP = ROOT / "src" / "bridge" / "bootstrap_service.odin"
PROVIDER_STORE = ROOT / "src" / "bridge" / "provider_store.odin"
PROVIDER_SEEDS = ROOT / "src" / "bridge" / "provider_seeds.odin"
OLD_CTL = ROOT / "src" / "ctl"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    client = CLIENT.read_text(encoding="utf-8")
    main_src = MAIN.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    provider_store = PROVIDER_STORE.read_text(encoding="utf-8")
    provider_seeds = PROVIDER_SEEDS.read_text(encoding="utf-8")

    # Launch/stop still flows through these entry points, and the Bridge remains
    # the sole materializer + endpoint selector for the launched agent.
    for marker in [
        "bridge_runtime_launch_agent :: proc",
        "bridge_bootstrap_launch_materialize_run_dir",
        "bridge_runtime_ensure_local_endpoint",
        "bridge_runtime_record_launch",
        "bridge_runtime_stop_agent :: proc",
        "bridge_runtime_remove_launch",
        "bridge_runtime_select_endpoint",
        "bridge_runtime_local_endpoint_descriptor",
        "bridge_runtime_local_endpoint_unix_started",
        "bridge_runtime_local_endpoint_loopback_started",
    ]:
        require(marker in client, f"missing launch marker: {marker}")

    # pty-host is the only agent-launch runtime: spawn/close go through the
    # ham-pty-host daemon, and the launch record is keyed by the pty-host pid.
    for marker in [
        "bridge_runtime_launch_agent_pty_host",
        "bridge_pty_host_ensure_daemon",
        "bridge_pty_host_build_spawn",
        "bridge_pty_host_spawn(socket, req)",
        "bridge_pty_host_is_registered",
        "bridge_pty_host_close",
        "ham-pty-host daemon unavailable",
        "pty-host:%d",
    ]:
        require(marker in client, f"missing pty-host launch marker: {marker}")

    for marker in [
        "bridge_runtime_resolve_provider_executable",
        "bridge_runtime_find_on_path(trimmed)",
        "bridge_provider_default_skill_dir",
    ]:
        require(marker in provider_store, f"missing provider store marker: {marker}")

    # Provider skill dirs are seeded (no inline switch): pi -> .pi/skills,
    # antigravity (agy) -> .agents/skills.
    for marker in [
        'name = "pi"',
        'skill_dir = ".pi/skills"',
        'name = "antigravity"',
        'command = {"agy"}',
        'skill_dir = ".agents/skills"',
    ]:
        require(marker in provider_seeds, f"missing provider seed marker: {marker}")

    for marker in [
        "pty_host_runtime",
        "wrapper-supervisor is removed; use ham-wrapper bridge-runtime",
    ]:
        require(marker in main_src, f"missing Bridge config marker: {marker}")

    for marker in [
        "if !bridge_bootstrap_write_ham_ctl_wrapper(run_dir, bridge_endpoint, agent_token, instance_id) do return false",
        "HEIMDALL_HAM_CTL_BIN",
        "bridge bootstrap failed: ham-ctl not found",
        "if skill_dir == \"\" do skill_dir = bridge_provider_default_skill_dir(provider)",
    ]:
        require(marker in bootstrap, f"missing bootstrap marker: {marker}")

    # The launch path must NOT resurrect the removed ham-wrapper argv / tmux
    # window management.
    for forbidden in [
        "bridge_runtime_ham_wrapper_argv",
        "tmux.ensure_agent_window",
        "tmux.kill_window",
        "--child-agent-token",
    ]:
        require(forbidden not in client, f"launch_agent must not use removed wrapper/tmux marker: {forbidden}")

    require(
        "bridge_runtime_select_endpoint(local_config)" in client
        and "bridge_runtime_local_endpoint_unix_started" in client
        and "bridge_runtime_local_endpoint_loopback_started" in client,
        "launch must select live endpoint per Unix-primary/loopback-fallback contract",
    )

    # The removed wrapper launch path must not have been migrated into src/ctl.
    old_ctl_text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_CTL.rglob("*.odin"))
    require("bridge_runtime_launch_agent" not in old_ctl_text, "src/ctl must not carry the Bridge launch path")
    require("wrapper-supervisor" not in old_ctl_text, "src/ctl must not carry the removed wrapper-supervisor")

    print("PASS: bridge real launch static")


if __name__ == "__main__":
    main()
