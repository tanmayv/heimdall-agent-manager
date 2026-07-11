#!/usr/bin/env python3
"""Source-level regression for daemon-mediated Guide UI debug bridge."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
GUIDE_RPC = ROOT / "src/daemon/guide_rpc.odin"
HTTP_CLIENT = ROOT / "src/lib/http_client/http_client.odin"
DEBUG_SERVER = ROOT / "src/ui/electron/debugServer.cts"
REGISTRY = ROOT / "src/ui/electron/instanceRegistry.cts"
PLAN = ROOT / ".heimdall/guide-agent-plan.md"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    rpc = GUIDE_RPC.read_text()
    http_client = HTTP_CLIENT.read_text()
    debug = DEBUG_SERVER.read_text()
    registry = REGISTRY.read_text()
    plan = PLAN.read_text()

    require('guide_ui_debug_status' in rpc and 'guide_ui_debug_action' in rpc, "guide RPC must expose UI debug bridge actions")
    require('guide_rpc_ui_debug_registry_path' in rpc and 'debug-instances.json' in rpc, "daemon must discover Electron debug registry")
    require('import http "odin_test:lib/http_client"' in rpc and 'http.get(base, path)' in rpc, "daemon must proxy through its HTTP client")
    for action in ['"info"', '"state"', '"elements"', '"logs"']:
        require(action in rpc, f"read-only UI debug action missing: {action}")
    require('unsupported or mutating UI debug action' in rpc, "mutating UI debug actions must not run without delegation")
    require('GUIDE_UI_DEBUG' in rpc, "UI debug bridge must audit/log guide debug calls")
    require('response_transfer_chunked' in http_client and 'response_decode_chunked_body' in http_client, "HTTP client must decode chunked Electron debug responses before proxying JSON")

    for endpoint in ['/info', '/state', '/elements', '/logs']:
        require(f"path: '{endpoint}'" in debug, f"Electron debug server missing endpoint {endpoint}")
    require('debug-instances.json' in registry and 'updatePort' in registry, "Electron must publish debug server port in registry")
    require('Phase 4: UI debug bridge' in plan, "guide plan should track phase 4")

    print('TEST PASSED: guide UI debug bridge scaffolding')


if __name__ == '__main__':
    main()
