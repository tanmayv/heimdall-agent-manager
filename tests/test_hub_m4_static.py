#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text()
def require(c,m):
    if not c: raise AssertionError(m)
def main():
    client=read('src/bridge/hub_runtime_client.odin')
    main_src=read('src/bridge/main.odin')
    for s in ['bridge_hub_runtime_worker','connect_with_bearer','/api/v1/bridge-ws','bridge_hello','capabilities','provider','tiers','default_tier','bridge_heartbeat','launch_agent','stop_agent','command_result','agent_instance_status','state_seq']:
        require(s in client, f'missing real bridge runtime support {s}')
    require('bridge_runtime_cached_command' in client and 'bridge_runtime_cache_command' in client, 'command idempotency cache missing')
    require('bridge_hub_runtime_start()' in main_src, 'real bridge runtime worker not started')
    ws_lib=read('src/lib/ws/ws.odin')
    http_client=read('src/lib/http_client/http_client.odin')
    require('bridge_hub_base_url_for_runtime' in client and 'http://' in client and 'ws://' in client and 'https://' in client and 'wss://' in client, 'runtime WS URL must derive ws:// or wss:// from persisted Hub URL')
    require('wss://' in ws_lib and 'tls_client_command' in ws_lib and '-verify_hostname' in ws_lib and '-servername' in ws_lib, 'WebSocket client must support WSS with TLS hostname validation/SNI')
    require('https://' in http_client and 'request_tls_with_headers' in http_client and '-verify_hostname' in http_client and '-servername' in http_client, 'HTTP client must support HTTPS with TLS hostname validation/SNI')
    require('bridge_enroll_command' in main_src and '--hub' in main_src and 'http:// or https://' in main_src, 'ham-bridge enroll --hub HTTP/HTTPS validation missing')
    require('bridge_bootstrap_fetch_and_materialize' in read('src/bridge/bootstrap_service.odin'), 'bootstrap materialization missing')
    print('PASS: hub M4 static')
if __name__=='__main__': main()
