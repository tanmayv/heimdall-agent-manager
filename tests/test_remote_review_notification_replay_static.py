from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / 'src/daemon/task_notifications.odin').read_text(encoding='utf-8')
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')


def require(cond: bool, msg: str):
    if not cond:
        print(f'FAIL: {msg}')
        sys.exit(1)


require('delivery := task_notify_recipient_delivery(p.agent_instance_id, payload)' in TEXT,
        'review_ready required-reviewer path should use delivery-aware notification handling')
require('if !delivery.failed do notified_count += 1' in TEXT,
        'review_ready required-reviewer path should count durable queue as covered delivery')
require('delivery := task_notify_recipient_delivery(default_reviewer, payload)' in TEXT,
        'review_ready default-reviewer fallback should use delivery-aware handling')
require('delivery := task_notify_recipient_delivery(coord, payload)' in TEXT,
        'review_ready coordinator fallback should use delivery-aware handling')
require('return !delivery.failed' in TEXT,
        'task_notify_recipient should treat durable queue as successful coverage')
require('notification_outbox_replay_pending(agent.agent_instance_id)' in PEERS,
        'peer relink should still replay queued notifications for remote proxies')

print('remote_review_notification_replay_static: ok')
