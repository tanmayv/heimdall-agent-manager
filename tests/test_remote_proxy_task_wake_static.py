from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
NUDGE = (ROOT / "src/daemon/task_nudge_scheduler.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


# Shared chokepoint: assignee, coordinator, and reviewer all route through
# task_autoscaler_ensure_agent, so the remote-wake branch must live there to
# cover all three roles (not just the reviewer).
require('task_autoscaler_ensure_agent :: proc' in NUDGE, "ensure_agent chokepoint missing")
ea_idx = NUDGE.index('task_autoscaler_ensure_agent :: proc')
ea_head = NUDGE[ea_idx:ea_idx + 700]
require('agent_record_is_remote_proxy(agent_instance_records[idx])' in ea_head, "ensure_agent must detect remote-proxy targets before local launch machinery")
require('task_autoscaler_ensure_remote_agent(' in ea_head, "ensure_agent must delegate remote targets to the wake path")

# Remote wake forwards a start to the owning peer for ALL roles.
require('task_autoscaler_ensure_remote_agent :: proc' in NUDGE, "missing remote wake entry point")
require('federation_forward_start(peer_id, remote_agent_instance_id, provider_profile, model_tier, proxy_agent_instance_id)' in NUDGE, "remote wake must forward start to owning peer")

# Unreachable peer: do not forward; durable outbox already carries the event.
require('if !federation_peer_reachable(peer_id)' in NUDGE, "remote wake must skip forwarding when peer unreachable")

# Already-live short-circuit uses propagated status (Part B), avoiding needless starts.
require('federation_agent_status_is_live(remote.status)' in NUDGE, "remote wake should no-op when the remote agent is already live")

# Coalescing so periodic reconcile ticks don't spam the peer while booting.
require('task_autoscaler_remote_wake_should_forward(' in NUDGE, "remote wake must coalesce repeated forwards")
require('REMOTE_WAKE_COALESCE_MS' in NUDGE, "remote wake must define a coalescing window")

print('remote_proxy_task_wake_static: ok')
