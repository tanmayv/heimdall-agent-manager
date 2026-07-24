#!/usr/bin/env python3
"""Static guard for RTE2E-5 thin Bridge-local wrapper supervisor."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE_MAIN = ROOT / "src" / "bridge" / "main.odin"
SUPERVISOR = ROOT / "src" / "bridge" / "wrapper_supervisor.odin"
OLD_WRAPPER = ROOT / "src" / "wrapper"
OLD_CTL = ROOT / "src" / "ctl"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    main_src = BRIDGE_MAIN.read_text(encoding="utf-8")
    sup = SUPERVISOR.read_text(encoding="utf-8")
    for marker in [
        "bridge_wrapper_supervisor_main",
        "HEIMDALL_BRIDGE_ENDPOINT",
        "HEIMDALL_AGENT_TOKEN",
        "HEIMDALL_AGENT_INSTANCE_ID",
        "--agent-command",
        "os.process_start",
        "os.process_wait(process, 0)",
        "bridge_wrapper_child_env",
        "bridge_wrapper_env_key_allowed",
        "wrapper.startup.report",
        "wrapper.activity.report",
        "wrapper.liveness.ping",
        "wrapper.exited",
        "bridge_wrapper_send_tcp",
        "bridge_wrapper_send_unix",
    ]:
        require(marker in sup, f"missing wrapper supervisor marker: {marker}")
    require("wrapper-supervisor" in main_src and "bridge_wrapper_supervisor_main(os.args)" in main_src, "ham-bridge must expose wrapper-supervisor entrypoint")
    forbidden = ["hub_url", "Hub token", "/api/v1", "Authorization", "Bearer ", "--user-token", "HAM_HUB_USER_TOKEN"]
    for marker in forbidden:
        require(marker not in sup, f"wrapper supervisor must not couple to Hub credentials/API: {marker}")
    require("os.environ" not in sup, "wrapper supervisor must not bulk-forward parent environment to the child agent")
    require("HEIMDALL_BRIDGE_ENDPOINT=" in sup and "HEIMDALL_AGENT_TOKEN=" in sup and "HEIMDALL_AGENT_INSTANCE_ID=" in sup, "sanitized child env must inject local endpoint variables")
    old_wrapper_text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_WRAPPER.rglob("*.odin"))
    require("bridge_wrapper_supervisor_main" not in old_wrapper_text, "old current-daemon src/wrapper must remain untouched by Bridge supervisor")
    old_ctl_text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_CTL.rglob("*.odin"))
    require("wrapper-supervisor" not in old_ctl_text, "old/current src/ctl must not be migrated to wrapper-supervisor in RTE2E-5")
    print("PASS: bridge wrapper supervisor static")


if __name__ == "__main__":
    main()
