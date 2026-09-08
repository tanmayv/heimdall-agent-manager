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
    
    require("127.0.0.1:8080" in users_odin, "dev_proxy listen must default to 127.0.0.1:8080")
    require("49322" in users_odin, "dev_proxy hub_url must default to 49322")
    require('os.get_env("USER"' in users_odin, "dev_proxy must dynamically resolve default user from USER")
    require("HAM_DEV_PROXY_DEFAULT_USER" in users_odin, "dev_proxy must support HAM_DEV_PROXY_DEFAULT_USER override")
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
    require("graph.agents.audit_mode = cfg.audit_mode" in hub_wiring or "graph.agents.audit_mode = config.audit_mode" in hub_wiring, "Hub wiring must propagate audit_mode to agents")
    require("graph.content.audit_mode = cfg.audit_mode" in hub_wiring or "graph.content.audit_mode = config.audit_mode" in hub_wiring, "Hub wiring must propagate audit_mode to content")

    # Verify elimination of hardcoded owner strings and presence of dynamic resource owner checks
    require("tanmayvijay" not in agent_svc, "agent_service must NOT contain hardcoded tanmayvijay strings")
    require("tanmayvijay" not in content_svc, "content_service must NOT contain hardcoded tanmayvijay strings")
    require("agent_owner := string(agent.owner_user_id)" in agent_svc, "agent_service must match against agent.owner_user_id")
    require("conv_owner := string(c.owner_user_id)" in content_svc, "content_service must match against conversation owner")
    require("audit mode active: agent spawning disabled for non-owner" in agent_svc, "Agent service must reject non-owner spawning in audit mode")
    require("audit mode active: pane capture/PTY operations disabled for non-owner" in content_svc, "Content service must reject non-owner PTY/pane capture in audit mode")

    require("audit_mode: bool" in bridge_main, "Bridge_Config must contain audit_mode")
    require("--audit-mode" in bridge_main, "Bridge main must support --audit-mode CLI flag")
    require("audit mode active: agent spawning and PTY allocation disabled" in bridge_client, "Bridge must reject launch_agent under audit_mode")

    # 3. Check LOAS ingress check and hardened proxy-to-Hub trust
    proxy_odin = (ROOT / "src/dev_proxy/proxy.odin").read_text(encoding="utf-8")
    gcert_proxy = (ROOT / "src/dev_proxy/gcert.odin").read_text(encoding="utf-8")
    auth_svc = (ROOT / "src/hub/service/auth/auth_service.odin").read_text(encoding="utf-8")

    require("dev_proxy_check_gcert" in gcert_proxy, "dev_proxy must define dev_proxy_check_gcert")
    require("dev_proxy_check_gcert" in main_proxy, "dev_proxy must call dev_proxy_check_gcert before forwarding")
    require("LOAS/gcert credential expired or missing" in gcert_proxy, "dev_proxy must report LOAS/gcert credential status")

    require('strings.has_prefix(lower, "x-authentik-")' in proxy_odin, "dev_proxy must strip all client x-authentik-* headers")
    require('strings.has_prefix(lower, "x-forwarded-")' in proxy_odin, "dev_proxy must strip all client x-forwarded-* headers")
    require('lower == "forwarded"' in proxy_odin, "dev_proxy must strip client Forwarded header")
    require('lower == "x-real-ip"' in proxy_odin, "dev_proxy must strip client X-Real-IP header")
    require('lower == "x-heimdall-proxy-secret"' in proxy_odin, "dev_proxy must strip client X-Heimdall-Proxy-Secret header")
    require("X-Heimdall-Proxy-Secret" in proxy_odin, "dev_proxy must inject X-Heimdall-Proxy-Secret when configured")

    require("proxy_secret: string" in hub_config, "Hub_Config must contain proxy_secret")
    require("X-Heimdall-Proxy-Secret" in auth_svc, "auth_service must verify X-Heimdall-Proxy-Secret")
    require("ensure_hub_proxy_secret" in hub_wiring, "Hub wiring must call ensure_hub_proxy_secret")
    require("--proxy-secret" in hub_main, "Hub main must support --proxy-secret flag")

    require('selected = "reviewer"' in users_odin, "dev_proxy must default unauthenticated requests to reviewer in audit mode")

    print("ALL CT-3 & CT-4 STATIC CHECKS PASSED")

if __name__ == "__main__":
    main()
