#!/usr/bin/env python3
"""Static guard for Runtime E2E RTE2E-6 ham-ctl Hub user mode."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CTL = ROOT / "src" / "ctl" / "main.odin"
OLD_WRAPPER = ROOT / "src" / "wrapper"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    ctl = CTL.read_text(encoding="utf-8")
    require("ctl_hub_user_mode" in ctl, "ham-ctl must expose explicit Hub user mode")
    require("hub_user_mode_url" in ctl and "--hub-url" in ctl and "HAM_HUB_URL" in ctl, "Hub user mode must configure Hub URL")
    require("hub_user_mode_token" in ctl and "--user-token" in ctl and "HAM_HUB_USER_TOKEN" in ctl, "Hub user mode must configure user token")
    require('name = "Authorization"' in ctl and '"Bearer "' in ctl and "request_with_headers_timeout" in ctl, "user token must be sent as Authorization bearer header")

    for marker in [
        "/api/v1/me",
        "/api/v1/agents",
        "/api/v1/agent-instances",
        "/api/v1/chats",
        "/api/v1/task-chains",
        "/tasks",
        "/messages",
        "/publish",
        "/status",
        "/nudge",
    ]:
        require(marker in ctl, f"missing Hub /api/v1 route marker: {marker}")

    hub_segment = ctl[ctl.index("ctl_hub_user_mode"):ctl.index("ctl_agents_list")]
    require('?token' not in hub_segment and 'access_token' not in hub_segment, "Hub user mode must not put bearer tokens in URL/query")
    require('json_kv("token"' not in hub_segment and 'json_kv("user_token"' not in hub_segment, "Hub user mode must not put bearer tokens in JSON body")
    require("ROUTE_AGENTS_START" in ctl and 'http.post(daemon_url, "/agents/create"' in ctl, "legacy current-daemon ctl routes must remain present")

    wrapper_text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_WRAPPER.rglob("*.odin"))
    require("HAM_HUB_USER_TOKEN" not in wrapper_text and "--user-token" not in wrapper_text, "old wrapper must not receive Hub user tokens")

    print("PASS: ham-ctl Hub user mode static")


if __name__ == "__main__":
    main()
