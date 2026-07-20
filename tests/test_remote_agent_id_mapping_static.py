from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ID_STORE = (ROOT / "src/daemon/agent_id_store.odin").read_text(encoding="utf-8")
AGENTS = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
PEERS = (ROOT / "src/daemon/federation_peers.odin").read_text(encoding="utf-8")
API = (ROOT / "src/ui/api/daemonApi.ts").read_text(encoding="utf-8")
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")
PICKER = (ROOT / "src/ui/components/AgentPicker.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)

require('remote_agent_id: string' in ID_STORE, 'Agent_Id_Record/Event must persist remote_agent_id')
require('agent_id_upsert_remote_proxy :: proc' in ID_STORE, 'missing durable remote agent_id upsert helper')
require('agent_id_record_is_remote_proxy :: proc' in ID_STORE, 'missing durable remote agent_id predicate')
require('agent_id_record_is_remote_proxy(agent_id_records[aid_idx])' in AGENTS, '/agents/start must detect durable remote agent_id')
require('federation_remote_agent_id_start_concrete(dest_daemon_id, remote_identity.remote_agent_id' in AGENTS, 'durable remote agent_id start must start remote durable agent_id')
require('agent_record_upsert(agent_instance_id, display_name, local_template_id, "", "", "", "", AGENT_IDENTITY_STATE_PROVISIONED, false, AGENT_KIND_REMOTE_PROXY' in AGENTS, 'durable remote start must persist local remote_proxy instance')
require('"remote_agent_instance_id"' in AGENTS, 'remote start response should expose returned concrete remote instance id')
require('local_agent_id' in PEERS and 'agent_id_upsert_remote_proxy' in PEERS, 'bind endpoint must accept/persist local remote agent_id mapping')
require('federation_remote_agent_id_create :: proc' in PEERS and '"/agent-ids/create"' in PEERS and 'create_remote_agent_id' in PEERS, 'bind endpoint must optionally create remote durable agent_id')
require('should_create_remote && (status != PEER_STATUS_LINKED' in PEERS, 'durable-only remote agent_id mapping should require reachability only when creating remote identity')
require('handle_agent_id_create :: proc' in AGENTS, 'daemon must expose durable agent_id create without concrete instance')
require('json_write_string(builder, agent_kind); strings.write_string(builder, `"`)' in AGENTS, 'agent_id identity JSON must close agent_kind string before following fields')
require('strings.write_string(builder, `,"remote":{"peer_id":"`)' in AGENTS, 'agent_id remote JSON object must follow agent_kind with comma, not an extra quote')
require('handle_get_federation_peer_agents' in PEERS and 'bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_GET, "/federation/agents"' in PEERS, 'local peer catalog route must fetch remote agent catalog over bridge')
require('provider?: string' in API and 'if (provider !== undefined)' in API and 'if (modelTier !== undefined)' in API, 'UI startAgent must allow omitting provider/tier for remote-owned runtime')
require('startInstance = true' in API and 'start_instance: Boolean(startInstance)' in API, 'UI API bind helper must support durable-only remote agent-id mapping')
require('agents-management-remote-agent-picker' in APP and 'remotePeersEnabled' in APP, 'Agents tab must expose remote agent picker/binder')
require('agents-management-remote-create-agent-id-btn' in APP and 'createRemoteAgentId: true' in APP and 'startInstance: false' in APP, 'Agents tab must create durable remote agent-id mappings without starting instances')
require('remoteAgentIsLive' in PICKER and 'if (isRemoteProxyAgent(agent)) return remoteAgentIsLive(agent)' in PICKER, 'AgentPicker must use remote liveness for remote proxies')

print('remote_agent_id_mapping_static: ok')
