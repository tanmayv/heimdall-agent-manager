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
require('remote_peer_id: string,' in STORE and 'remote_agent_instance_id: string,' in STORE, "remote proxy fields missing from agent store")
require('agent_remote_proxy_lookup :: proc' in STORE, "remote proxy lookup helper missing")
require('agent_remote_proxy_find :: proc' in STORE, "remote proxy reuse helper missing")
require('"agent_kind":"' in AGENTS, "agent JSON should expose agent_kind")
require('"remote":{"peer_id":"' in AGENTS, "agent JSON should emit remote block")
require('remote_proxy instances are dormant and cannot launch local wrappers' in AGENTS, "manual start guard missing")
require('handle_agent_reorder :: proc' in AGENTS and 'agent_kind = rec.agent_kind' in AGENTS and 'remote_peer_id = rec.remote_peer_id' in AGENTS and 'remote_agent_instance_id = rec.remote_agent_instance_id' in AGENTS, "agent reorder should preserve remote proxy metadata")
require('ctx.segments[1] == "proxies" && ctx.segments[2] == "bind"' in ROUTER, "missing federation proxy bind route")
require('handle_post_federation_proxy_bind :: proc' in FED, "missing federation proxy bind handler")
require('federation_remote_proxy_bind :: proc' in FED, "missing federation remote proxy bind helper")
require('AGENT_KIND_REMOTE_PROXY' in FED, "bind helper should create remote_proxy records")
require('remote_proxy instances cannot register local wrapper sessions' in LIFECYCLE, "wrapper register guard missing")
require('stage=remote_proxy_skip' in SCHED, "autoscaler remote proxy skip guard missing")
require('export async function bindRemoteProxy' in API, "UI API helper for remote proxy bind missing")

print('remote_proxy_identity_static: ok')
