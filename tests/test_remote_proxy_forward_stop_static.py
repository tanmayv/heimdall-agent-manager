from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "src/contracts/bridge.odin").read_text(encoding="utf-8")
FED = (ROOT / "src/daemon/federation_transport.odin").read_text(encoding="utf-8")
STOP = (ROOT / "src/daemon/agents_stop.odin").read_text(encoding="utf-8")
ROUTER = (ROOT / "src/daemon/rest_router.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


# A1: route constant + authenticated-route match arm.
require('ROUTE_FEDERATION_STOP :: "/federation/stop"' in BRIDGE, "missing ROUTE_FEDERATION_STOP constant")
require('ROUTE_FEDERATION_START,\n\t     ROUTE_FEDERATION_STOP,' in BRIDGE, "ROUTE_FEDERATION_STOP missing from daemon route match arm")

# A2: sender side federation_forward_stop mirrors federation_forward_start.
require('federation_forward_stop :: proc(peer_id, remote_agent_instance_id: string, time_in_sec: int' in FED, "missing federation_forward_stop sender")
require('federation_idempotency_key("stop", server_daemon_id, remote_agent_instance_id)' in FED, "forward_stop should use a stop idempotency key")
require('contracts.ROUTE_FEDERATION_STOP' in FED, "forward_stop should request ROUTE_FEDERATION_STOP")
require('status != PEER_STATUS_LINKED' in FED, "forward_stop should require a linked peer")

# A3: receiver side handler + refusal to relay onward.
require('handle_post_federation_stop :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context)' in FED, "missing handle_post_federation_stop receiver")
require('refusing to relay stop' in FED, "receiver should refuse to relay onward for a remote proxy target")
require('stop_ok, status, msg := agents_stop_request(agent_instance_id, time_in_sec)' in FED, "receiver should delegate to core agents_stop_request")
require('ctx.segments[1] == "stop" && ctx.method == "POST"' in ROUTER, "missing /federation/stop dispatch")
require('handle_post_federation_stop(client, request_body(request), ctx)' in ROUTER, "router should dispatch federation stop handler")

# A4: local stop entry point detects proxy and forwards.
require('agent_record_is_remote_proxy(agent_instance_records[idx])' in STOP, "agents_stop_request should detect remote proxies")
require('federation_forward_stop(peer_id, remote_id, time_in_sec' in STOP, "agents_stop_request should forward stop to the owning peer")

print('remote_proxy_forward_stop_static: ok')
