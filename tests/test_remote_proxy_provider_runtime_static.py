from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
AGENTS = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
STORE = (ROOT / "src/daemon/agent_store.odin").read_text(encoding="utf-8")
PEERS = (ROOT / "src/daemon/federation_peers.odin").read_text(encoding="utf-8")
NUDGE = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text(encoding="utf-8")
STATUS = (ROOT / "src/daemon/federation_agent_status.odin").read_text(encoding="utf-8")
FED = (ROOT / "src/daemon/federation_transport.odin").read_text(encoding="utf-8")
CATALOG = (ROOT / "src/ui/api/agentCatalog.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


# Unsupported explicit provider overrides should fail on the daemon receiving a start.
require('agent_provider_profile_supported :: proc' in AGENTS, "missing provider support validator")
require('invalid provider_profile' in AGENTS and 'is not supported on this daemon' in AGENTS, "missing unsupported provider error")
require('if provider_profile != "" && !agent_provider_profile_supported(provider_profile)' in AGENTS, "handle_agents_start must reject unsupported explicit provider overrides")

# Remote proxy records must not persist local provider/tier defaults.
require('pp = ""' in AGENTS and 'tier = ""' in AGENTS and 'kind == AGENT_KIND_REMOTE_PROXY' in AGENTS, "agent_record_upsert must clear provider/tier for remote proxies")
require('if kind != AGENT_KIND_REMOTE_PROXY do tier = normalize_model_tier(event.model_tier)' in STORE, "store must not normalize empty remote proxy model_tier to normal")
require('if agent_record_is_remote_proxy(rec) { assoc_tier = ""; assoc_provider = "" }' in AGENTS, "associate path must keep remote proxy provider/tier empty")
require('if agent_record_is_remote_proxy(rec) { disassoc_tier = ""; disassoc_provider = "" }' in AGENTS, "disassociate path must keep remote proxy provider/tier empty")
require('agent_record_upsert(local_id, local_display_name, local_template_id, "", "", "", ""' in PEERS, "remote proxy bind must persist empty provider/tier")
require('existing.provider_profile != "" || existing.model_tier != ""' in PEERS, "bind should clear legacy local provider/tier on existing proxies")

# Task wake must not forward local proxy provider/tier; remote daemon owns runtime selection.
require('federation_forward_start(peer_id, remote_agent_instance_id, "", "", proxy_agent_instance_id)' in NUDGE, "remote task wake must omit provider/tier overrides")

# Runtime provider/tier should come from origin status propagation and be exposed on the proxy response.
require('provider_profile, model_tier := federation_agent_runtime_provider_tier' in STATUS, "origin status should include runtime provider/tier")
require('provider_profile = strings.clone(agent.provider_profile)' in STATUS, "origin status should read runtime provider")
require('model_tier = strings.clone(agent.provider_tier)' in STATUS, "origin status should read runtime tier")
require('provider_profile := extract_json_string(body, "provider_profile", "")' in FED, "callback receiver must parse runtime provider")
require('remote_proxy_status_apply(proxy_agent_instance_id, status_value, connection_state, current_task_id, provider_profile, model_tier' in FED, "callback receiver must store runtime provider/tier")
require('provider_profile_json = remote_status_for_json.provider_profile' in AGENTS, "agent JSON should return remote runtime provider for proxies")
require('model_tier = remote_status_for_json.model_tier' in AGENTS, "agent JSON should return remote runtime tier for proxies")
require("toLowerCase() === 'remote_proxy') ? (agent.model_tier || agent.modelTier || '')" in CATALOG, "UI catalog must not default remote proxy modelTier to normal")

print('remote_proxy_provider_runtime_static: ok')
