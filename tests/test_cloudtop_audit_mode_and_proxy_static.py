#!/usr/bin/env python3
"""Static regression tests for CT-3 & CT-4: Dev Proxy Cloudtop Setup & Code-Level Audit Mode."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)

def main() -> None:
    # 1. Check dev_proxy configuration and CSRF/host checks (CT-3)
    users_odin = (ROOT / "src/dev_proxy/users.odin").read_text(encoding="utf-8")
    main_proxy = (ROOT / "src/dev_proxy/main.odin").read_text(encoding="utf-8")
    
    require("tanmayvijay" in users_odin, "dev_proxy must include tanmayvijay in users")
    require("127.0.0.1:8080" in users_odin, "dev_proxy listen must default to 127.0.0.1:8080")
    require("49322" in users_odin, "dev_proxy hub_url must default to 49322")
    require("is_origin_or_referer_allowed" in main_proxy, "dev_proxy must validate Origin / Referer")
    require("Sec-Fetch-Site" in main_proxy, "dev_proxy must validate Sec-Fetch-Site")
    require("invalid host header" in main_proxy, "dev_proxy must reject non-loopback Host headers")
    require("cross-origin dev request rejected" in main_proxy, "dev_proxy must reject CSRF attempts")

    # 2. Check Hub & Bridge code-level audit mode (CT-4)
    hub_config = (ROOT / "src/hub/app/config_bind.odin").read_text(encoding="utf-8")
    hub_main = (ROOT / "src/hub/main.odin").read_text(encoding="utf-8")
    hub_wiring = (ROOT / "src/hub/app/wiring.odin").read_text(encoding="utf-8")
    agent_svc = (ROOT / "src/hub/service/agent/agent_service.odin").read_text(encoding="utf-8")
    content_svc = (ROOT / "src/hub/service/content/content_service.odin").read_text(encoding="utf-8")
    bridge_main = (ROOT / "src/bridge/main.odin").read_text(encoding="utf-8")
    bridge_client = (ROOT / "src/bridge/hub_runtime_client.odin").read_text(encoding="utf-8")

    require("audit_mode: bool" in hub_config, "Hub_Config must contain audit_mode")
    require("--audit-mode" in hub_main, "Hub main must support --audit-mode CLI flag")
    require("graph.agents.audit_mode = config.audit_mode" in hub_wiring, "Hub wiring must propagate audit_mode to agents")
    require("graph.content.audit_mode = config.audit_mode" in hub_wiring, "Hub wiring must propagate audit_mode to content")
    require("audit mode active: agent spawning disabled for non-owner" in agent_svc, "Agent service must reject non-owner spawning in audit mode")
    require("audit mode active: pane capture/PTY operations disabled for non-owner" in content_svc, "Content service must reject non-owner PTY/pane capture in audit mode")
    require("audit_mode: bool" in bridge_main, "Bridge_Config must contain audit_mode")
    require("--audit-mode" in bridge_main, "Bridge main must support --audit-mode CLI flag")
    require("audit mode active: agent spawning and PTY allocation disabled" in bridge_client, "Bridge must reject launch_agent under audit_mode")

    print("ALL CT-3 & CT-4 STATIC CHECKS PASSED")

if __name__ == "__main__":
    main()
