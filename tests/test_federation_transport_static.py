from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = (ROOT / 'src/daemon/federation_transport.odin').read_text(encoding='utf-8')
MESSAGE = (ROOT / 'src/daemon/message_service.odin').read_text(encoding='utf-8')
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')
ROUTER = (ROOT / 'src/daemon/rest_router.odin').read_text(encoding='utf-8')
TASK_DB = (ROOT / 'src/daemon/task_db_service.odin').read_text(encoding='utf-8')
TASK_NOTIF = (ROOT / 'src/daemon/task_notification_outbox.odin').read_text(encoding='utf-8')
WS_EVENTS = (ROOT / 'src/daemon/ws_events.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


require('registry_send_ws_text_or_remote :: proc' in TRANSPORT, 'remote delivery chokepoint helper missing')
require('handle_post_federation_inbox :: proc' in TRANSPORT, 'federation inbox handler missing')
require('handle_post_federation_callback :: proc' in TRANSPORT, 'federation callback handler missing')
require('handle_get_federation_message :: proc' in TRANSPORT, 'federation message body fetch handler missing')
require('federation_callback_origin_message_authorize :: proc' in TRANSPORT, 'callback scope authorization helper missing')
require('federation_delivery_dedupe_scope :: proc' in TRANSPORT, 'peer-scoped dedupe helper missing')
require('federation_delivery_dedupe_completed :: proc' in TRANSPORT, 'completed-only dedupe check missing')
require('federation_delivery_dedupe_record_completed :: proc' in TRANSPORT, 'completed-only dedupe record missing')
require('federation_idempotency_key :: proc' in TRANSPORT, 'idempotency key helper missing')
require('federation_remote_message_record_key :: proc' in TRANSPORT, 'remote message record-key helper missing')
require('federation_remote_message_store_reply_if_absent :: proc' in TRANSPORT, 'reply callback should persist replies idempotently before notify')
require('federation_delivery_outbox' in TASK_DB, 'federation delivery outbox table missing')
require('federation_delivery_dedupe' in TASK_DB, 'federation dedupe table missing')
require('federation_remote_messages' in TASK_DB, 'federation remote message table missing')
require('record_key TEXT PRIMARY KEY' in TASK_DB, 'remote message table should use a peer-scoped record key primary key')
require('federation_remote_send_message' in MESSAGE, 'message service should route remote proxy sends')
require('federation_remote_route_reply' in MESSAGE, 'message service should route remote replies')
require('federation_remote_fetch_messages' in MESSAGE, 'message service should merge proxied remote fetches')
require('"origin_message_id"' in TRANSPORT, 'reply callbacks should carry origin message id for scope checks')
require('federation_idempotency_key("msg", server_daemon_id' in TRANSPORT, 'message inbox idempotency keys should include origin daemon id')
require('federation_idempotency_key("reply", server_daemon_id' in TRANSPORT, 'reply callback idempotency keys should include origin daemon id')
require('federation_idempotency_key("read", server_daemon_id' in TRANSPORT, 'read receipt idempotency keys should include origin daemon id')
require('failed to durably queue notification' in TRANSPORT, 'notification inbox should fail closed when durable queue insert fails')
require('failed to record notification dedupe' in TRANSPORT, 'notification dedupe should record only after queue success')
require('failed to record inbox dedupe' in TRANSPORT, 'inbox message dedupe should record only after placeholder persistence')
require('failed to record callback dedupe' in TRANSPORT, 'callback dedupe should record only after callback mutation success')
require('owner_daemon_id != ?' in TRANSPORT, 'remote fetch/reply route lookups should exclude local origin-copy rows')
require('if event_id == "" {' in TRANSPORT, 'notification inbox should gate ACK on durable queue insertion')
require('federation_delivery_outbox_replay_peer(peer_id)' in PEERS, 'peer relink should replay queued federation deliveries')
require('registry_send_ws_text_or_remote(recipient_agent_instance_id' in TASK_NOTIF, 'notification replay should use remote-aware delivery')
require('registry_send_ws_text_or_remote(string(event.target_agent_instance_id)' in WS_EVENTS, 'message availability events should use remote-aware delivery')
require('ctx.segments[1] == "inbox"' in ROUTER, 'router missing /federation/inbox')
require('ctx.segments[1] == "callback"' in ROUTER, 'router missing /federation/callback')
require('ctx.segments[1] == "messages"' in ROUTER, 'router missing /federation/messages/{id}')
require('federation_delivery_dedupe_seen_or_record' not in TRANSPORT, 'pre-mutation dedupe helper should not remain in transport')

print('federation_transport_static: ok')
