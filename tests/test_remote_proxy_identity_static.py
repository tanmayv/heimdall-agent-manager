from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "src/daemon/agent_store.odin").read_text(encoding="utf-8")
AGENTS = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
ROUTER = (ROOT / "src/daemon/rest_router.odin").read_text(encoding="utf-8")
FED = (ROOT / "src/daemon/federation_peers.odin").read_text(encoding="utf-8")
LIFECYCLE = (ROOT / "src/daemon/lifecycle.odin").read_text(encoding="utf-8")
SCHED = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text(encoding="utf-8")
API = (ROOT / "src/ui/api/daemonApi.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


require('AGENT_KIND_REMOTE_PROXY :: "remote_proxy"' in STORE, "remote proxy kind constant missing")
require('remote_peer_id: string,' in STORE and 'remote_origin_daemon_id: string,' in STORE and 'remote_agent_instance_id: string,' in STORE, "remote proxy fields missing from agent store")
require('agent_remote_proxy_lookup :: proc' in STORE, "remote proxy lookup helper missing")
require('agent_remote_proxy_identity_lookup :: proc' in STORE, "absolute remote proxy lookup helper missing")
require('agent_remote_proxy_find :: proc' in STORE, "remote proxy reuse helper missing")
require('agent_remote_proxy_find_absolute :: proc' in STORE, "absolute remote proxy reuse helper missing")
require('agent_remote_proxy_origin_daemon_id :: proc' in STORE, "remote proxy origin fallback helper missing")
require('"agent_kind":"' in AGENTS, "agent JSON should expose agent_kind")
require('"remote":{"peer_id":"' in AGENTS and '"origin_daemon_id":"' in AGENTS, "agent JSON should emit remote block with origin_daemon_id")
require('Starting a remote_proxy must start the REAL agent on the owning peer' in AGENTS and 'federation_forward_start(proxy.remote_peer_id, proxy.remote_agent_instance_id' in AGENTS, "manual start should forward to the owning peer")
require('handle_agent_reorder :: proc' in AGENTS and 'agent_kind = rec.agent_kind' in AGENTS and 'remote_peer_id = rec.remote_peer_id' in AGENTS and 'remote_origin_daemon_id = rec.remote_origin_daemon_id' in AGENTS and 'remote_agent_instance_id = rec.remote_agent_instance_id' in AGENTS, "agent reorder should preserve remote proxy metadata")
require('ctx.segments[1] == "proxies" && ctx.segments[2] == "bind"' in ROUTER, "missing federation proxy bind route")
require('handle_post_federation_proxy_bind :: proc' in FED, "missing federation proxy bind handler")
require('federation_remote_proxy_bind :: proc' in FED, "missing federation remote proxy bind helper")
require('federation_remote_agent_id_start_concrete :: proc' in FED, "bind-by-agent-id must first start remote durable identity")
require('extract_json_string(resp.body, "agent_instance_id", "")' in FED, "bind-by-agent-id must parse returned concrete remote instance id")
require('extract_json_string(body, "remote_agent_id", "")' in FED, "bind endpoint must accept remote_agent_id")
require('remoteAgentId =' in API and 'remote_agent_id: remoteAgentId' in API, "UI API bind helper must support remoteAgentId")
require('agent_remote_proxy_find_absolute' in FED, "bind helper should prefer absolute identity reuse")
require('origin_daemon_id' in FED and 'native_id' in FED, "federation peer responses should expose absolute identity")
require('AGENT_KIND_REMOTE_PROXY' in FED, "bind helper should create remote_proxy records")
require('remote_proxy instances cannot register local wrapper sessions' in LIFECYCLE, "wrapper register guard missing")
require('stage=remote_proxy_skip' in SCHED, "autoscaler remote proxy skip guard missing")
require('export async function bindRemoteProxy' in API, "UI API helper for remote proxy bind missing")

print('remote_proxy_identity_static: ok')
