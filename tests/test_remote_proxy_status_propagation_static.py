from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
STATUS = (ROOT / "src/daemon/federation_agent_status.odin").read_text(encoding="utf-8")
FED = (ROOT / "src/daemon/federation_transport.odin").read_text(encoding="utf-8")
TRACKER = (ROOT / "src/daemon/agent_runtime_tracker.odin").read_text(encoding="utf-8")
PEERS = (ROOT / "src/daemon/federation_peers.odin").read_text(encoding="utf-8")
AGENTS = (ROOT / "src/daemon/agents_start.odin").read_text(encoding="utf-8")
CATALOG = (ROOT / "src/ui/api/agentCatalog.ts").read_text(encoding="utf-8")
REMOTE = (ROOT / "src/ui/api/agentRemote.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


# B1: envelope + derived status enum + propagation entry point.
require('FEDERATION_ENVELOPE_AGENT_STATUS :: "agent_status"' in FED, "missing agent_status envelope constant")
require('federation_derive_agent_status :: proc' in STATUS, "missing derived status resolver")
require('federation_propagate_agent_status :: proc' in STATUS, "missing propagation entry point")
require('federation_agent_status_resync_peer :: proc' in STATUS, "missing reconnect snapshot resync")

# B0: transition-only. Propagation must self-suppress on unchanged status and
# mutate the backing subscriber array by index (not a loop copy), otherwise
# last_sent_status never sticks and every heartbeat edge becomes a firehose.
require('if sub.last_sent_status == status do continue' in STATUS, "propagation must skip unchanged status (no heartbeat firehose)")
require('for i in 0..<len(agent_status_subscribers)' in STATUS and 'sub := &agent_status_subscribers[i]' in STATUS, "subscriber status updates must mutate backing array by index")

# Edge-triggered wiring: only inside existing lifecycle/runtime edges, never per raw heartbeat.
require('federation_propagate_agent_status(snap.agent_instance_id, "heartbeat")' in TRACKER, "propagation must piggyback on heartbeat edges")
require(TRACKER.count('federation_propagate_agent_status') >= 6, "propagation should be wired at multiple lifecycle edges")
# Ensure the heartbeat propagation is gated by the change flags, not unconditional.
hb_idx = TRACKER.index('registry_apply_heartbeat_snapshot(snap)')
hb_section = TRACKER[hb_idx:hb_idx + 900]
require('if !was_live || lifecycle_changed {' in hb_section and 'if runtime_changed {' in hb_section, "heartbeat propagation must stay gated behind change flags")

# B2: proxy side stores remote status, drops stale, emits only on transition.
require('remote_proxy_status_apply :: proc' in STATUS, "missing proxy-side status apply")
require('updated_unix_ms < rec.updated_unix_ms' in STATUS, "must drop stale/out-of-order updates")
require('agent_proxy_status_emit :: proc' in STATUS, "missing proxy-side local UI emit")
require('case FEDERATION_ENVELOPE_AGENT_STATUS:' in FED, "callback receiver must handle agent_status")
require('if changed do agent_proxy_status_emit' in FED, "must emit local UI event only on transition")

# Subscriber authorization: register only via authenticated forwarded start/stop.
require('agent_status_subscriber_register :: proc' in STATUS, "missing subscriber register")
require('agent_status_subscriber_register(peer_id, proxy_agent_instance_id, agent_instance_id)' in FED, "forwarded start/stop must register the subscriber")

# Subscriber index must be bounded: lazy-prune dead subscribers.
require('agent_status_subscriber_prune_locked :: proc' in STATUS, "missing lazy prune for subscriber index")
require('agent_status_subscriber_is_dead :: proc' in STATUS, "missing dead-subscriber detection")
require('agent_status_subscriber_prune_locked()' in STATUS, "register/propagate must prune dead subscribers")

# String clones must not leak on overwrite.
require('agent_status_subscriber_set_last_sent_locked :: proc' in STATUS, "last_sent_status overwrite must free prior clone")
require('if rec.status != "" do delete(rec.status)' in STATUS, "remote_proxy_status_apply must free prior status clone")

# Shared lifecycle JSON writer so proxy + live emits cannot drift.
LIFE = (ROOT / "src/daemon/agent_lifecycle_notifications.odin").read_text(encoding="utf-8")
require('agent_lifecycle_changed_write :: proc' in LIFE, "missing shared agent_lifecycle_changed writer")
require('agent_lifecycle_changed_write(&b, Agent_Lifecycle_Event_Fields{' in STATUS, "proxy emit must reuse the shared lifecycle writer")
require('agent_lifecycle_changed_write(&builder, Agent_Lifecycle_Event_Fields{' in LIFE, "live emit must reuse the shared lifecycle writer")

# B3: JSON exposure + peer-unreachable override.
require('federation_peer_reachable :: proc' in STATUS, "missing peer reachability helper")
require('if !peer_reachable do effective_status = FEDERATION_AGENT_STATUS_OFFLINE' in AGENTS, "unreachable peer must override to offline")
require('"peer_reachable":' in AGENTS, "remote JSON must expose peer_reachable")
require('"status":"' in AGENTS and '"current_task_id":"' in AGENTS, "remote JSON must expose status + current_task_id")

# B1 reconnect snapshot wired on link reconnect.
require('federation_agent_status_resync_peer(replay_peer_ids[i])' in PEERS, "reconnect must push one status snapshot per subscriber")

# UI consumes real status.
require('status: agent.remote.status' in CATALOG, "agentCatalog must map remote.status")
require('peerReachable' in CATALOG, "agentCatalog must map peer_reachable")
require('remoteAgentIsLive' in REMOTE and 'remoteAgentStatus' in REMOTE, "shared remote helpers must expose liveness + status")
require("LIVE_REMOTE_STATUSES" in REMOTE, "remoteAgentIsLive must gate on live statuses")

print('remote_proxy_status_propagation_static: ok')
