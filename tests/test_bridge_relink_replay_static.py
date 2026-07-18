from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')
OUTBOX = (ROOT / 'src/daemon/task_notification_outbox.odin').read_text(encoding='utf-8')
TRANSPORT = (ROOT / 'src/daemon/federation_transport.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


require('reachable_daemon_apply_entry_locked :: proc(entry: string, changed_ids: ^strings.Builder, changed_count: ^int, replay_peer_ids: []string, replay_count: ^int)' in PEERS, 'reachability apply helper must collect replay peer ids instead of replaying under lock')
require('old_last_seen_unix_ms := rec.last_seen_unix_ms' in PEERS, 'must capture prior bridge last_seen before apply')
require('new_last_seen_unix_ms := i64(extract_json_int(entry, "last_seen_unix_ms", 0))' in PEERS, 'must parse bridge last_seen from snapshot')
require('old_status != PEER_STATUS_LINKED || old_last_seen_unix_ms != new_last_seen_unix_ms' in PEERS, 'linked relink with changed last_seen must trigger replay even if stale daemon status was already linked')
require('replay_peer_ids[replay_count^] = strings.clone(peer_id)' in PEERS, 'relink apply must enqueue replay outside the reachability mutex')
require('sync.mutex_unlock(&reachable_daemon_mutex)\n\tfor i in 0..<replay_count' in PEERS, 'replays must occur after releasing reachability mutex to avoid hydrate/replay deadlock')
require('federation_delivery_outbox_replay_peer(replay_peer_ids[i])' in PEERS, 'federation delivery outbox replay must run on relink')
require('peer_link_replay_remote_notifications(replay_peer_ids[i])' in PEERS, 'remote notification outbox replay must run on relink')

replay = re.search(r'notification_outbox_replay_pending :: proc\(.*?\) -> int \{(.*?)\n\}', OUTBOX, re.S)
require(replay is not None, 'notification outbox replay helper missing')
replay_body = replay.group(1)
require('registry_send_ws_text_or_remote_transport_accepted' in replay_body, 'remote notification replay must attempt bridge transport')
require('notification_outbox_mark_attempt(recipient_agent_instance_id, event_ids[i], false)' in replay_body, 'remote bridge acceptance must not mark delivered')
require('notification_outbox_mark_remote_ack' in OUTBOX or 'notification_outbox_mark_remote_ack' in TRANSPORT, 'delivery ACK must remain separate from transport acceptance')

forward = re.search(r'federation_forward_transport_accepted :: proc\(.*?\) -> bool \{(.*?)\n\}', TRANSPORT, re.S)
require(forward is not None, 'transport accepted helper missing')
forward_body = forward.group(1)
require('federation_direct_peer_lookup(peer_id, "")' in forward_body, 'transport attempts must use bridge projection lookup')
require('delivered' not in forward_body, 'transport accepted helper must not mark business delivery')

print('bridge_relink_replay_static: ok')
