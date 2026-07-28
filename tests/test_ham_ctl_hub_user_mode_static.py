#!/usr/bin/env python3
"""Static guard for Runtime E2E RTE2E-6 ham-ctl Hub user mode."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "src" / "ctl" / "main.odin"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    text = CTL.read_text(encoding="utf-8")
    start = text.index("ctl_hub_user_mode :: proc")
    end = text.index("ctl_agents_list :: proc", start)
    hub = text[start:end]

    for marker in [
        "--hub-url",
        "--user-token",
        "HEIMDALL_HUB_URL",
        "HEIMDALL_USER_TOKEN",
        "request_with_headers_timeout",
        "Authorization",
        "Bearer ",
        "/api/v1/me",
        "/api/v1/agents",
        "/api/v1/agent-instances",
        "/api/v1/chats",
        "/api/v1/task-chains",
        "/messages",
        "/publish",
        "/status",
        "/nudge",
    ]:
        require(marker in hub, f"missing Hub user-mode marker: {marker}")

    require("token=" not in hub, "Hub user mode must not put bearer tokens in query strings")
    require('json_kv("token"' not in hub and 'json_kv("user_token"' not in hub, "Hub user mode must not serialize bearer tokens into request bodies")
    require("Authorization" in hub and "user_token" in hub and "Bearer " in hub, "Hub user token must be used as Authorization bearer header")

    # RTE2E-9: legacy daemon/current ctl command paths remain present for existing users.
    for legacy in [
        "contracts.ROUTE_AGENTS_START",
        "contracts.ROUTE_AGENT_RPC",
        "ctl_tasks(daemon_url",
        "ctl_artifacts(daemon_url",
        "ctl_chat(daemon_url",
    ]:
        require(legacy in text, f"legacy ctl behavior marker missing: {legacy}")

    print("PASS: ham-ctl Hub user mode static")


if __name__ == "__main__":
    main()
