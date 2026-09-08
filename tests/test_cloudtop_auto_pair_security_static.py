#!/usr/bin/env python3
"""Static regression tests for CT-1 & CT-2 Security Hardening: Loopback Auto-Pairing & Bridge Token."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)

def main() -> None:
    # 1. Check auto-pair loopback guard & proxy rejection in bridge_handlers.odin
    handlers_odin = (ROOT / "src/hub/transport/http/bridge_handlers.odin").read_text(encoding="utf-8")
    require("is_loopback_ip" in handlers_odin, "bridge_handlers must define is_loopback_ip")
    require('ip == "" do return false' in handlers_odin, "is_loopback_ip must explicitly reject empty string")
    require('::ffff:127.0.0.1' in handlers_odin, "is_loopback_ip must support IPv4-mapped IPv6")
    require('X-Forwarded-For' in handlers_odin, "auto_pair_bridge_handler must check X-Forwarded-For")
    require('X-Forwarded-Host' in handlers_odin, "auto_pair_bridge_handler must check X-Forwarded-Host")
    require('X-Real-IP' in handlers_odin, "auto_pair_bridge_handler must check X-Real-IP")
    require('auto-pairing is forbidden via proxy headers' in handlers_odin, "auto_pair_bridge_handler must reject proxy headers")
    require('!is_loopback_ip(req.remote_addr)' in handlers_odin, "auto_pair_bridge_handler must guard with is_loopback_ip")

    # 2. Check dev-proxy blocks bridge pairing routes
    proxy_main = (ROOT / "src/dev_proxy/main.odin").read_text(encoding="utf-8")
    require('/api/v1/bridges/auto-pair' in proxy_main, "dev-proxy must intercept /api/v1/bridges/auto-pair")
    require('/api/v1/bridges/enroll' in proxy_main, "dev-proxy must intercept /api/v1/bridges/enroll")
    require('bridge enrollment/auto-pair forbidden through dev-proxy' in proxy_main, "dev-proxy must return 403 for auto-pair/enroll")

    # 3. Check elimination of static credential backdoor in bridge_service.odin
    bridge_svc = (ROOT / "src/hub/service/bridge/bridge_service.odin").read_text(encoding="utf-8")
    require('token == "hbr_local_secret"' not in bridge_svc, "bridge_service must NOT contain static fallback in verify_bridge_token")
    require('read_loopback_token_file' in bridge_svc, "bridge_service must support reading loopback token file")
    require('write_loopback_token_file' in bridge_svc, "bridge_service must support writing loopback token file")
    require('bridge_token' in bridge_svc, "bridge_service must reference bridge_token path")

    # 4. Check bridge/main.odin loads token from file and avoids static fallback
    bridge_main = (ROOT / "src/bridge/main.odin").read_text(encoding="utf-8")
    require('bridge_token = "hbr_local_secret"' not in bridge_main, "bridge main config must not default to hbr_local_secret")
    require('bridge_read_token_file' in bridge_main, "bridge main must read token file")

    print("ALL CT-1 & CT-2 SECURITY HARDENING CHECKS PASSED")

if __name__ == "__main__":
    main()
