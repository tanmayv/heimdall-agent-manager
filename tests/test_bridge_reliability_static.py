from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / 'src/bridge/main.odin').read_text(encoding='utf-8')
CONTRACTS = (ROOT / 'src/contracts/bridge.odin').read_text(encoding='utf-8')
WS = (ROOT / 'src/lib/ws/ws.odin').read_text(encoding='utf-8')
DAEMON_HTTP = (ROOT / 'src/daemon/http.odin').read_text(encoding='utf-8')
HTTP_CLIENT = (ROOT / 'src/lib/http_client/http_client.odin').read_text(encoding='utf-8')
ARTIFACT_HTTP = (ROOT / 'src/daemon/artifact_http.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


# Explicit reliability/backpressure limits are shared contract constants, not
# magic numbers hidden in bridge code.
for symbol in [
    'BRIDGE_WS_MAX_CHUNK_PAYLOAD_BYTES',
    'BRIDGE_WS_MAX_TRANSIT_QUEUE_FRAMES',
    'BRIDGE_WS_MAX_TRANSIT_QUEUE_BYTES',
    'BRIDGE_WS_TRANSIT_QUEUE_TTL_MS',
    'BRIDGE_WS_MAX_REASSEMBLIES',
    'BRIDGE_WS_MAX_REASSEMBLY_BYTES',
    'BRIDGE_WS_MAX_CHUNK_COUNT',
    'BRIDGE_WS_CHUNK_ACK_TIMEOUT_MS',
    'BRIDGE_WS_CHUNK_MAX_SEND_ATTEMPTS',
    'BRIDGE_WS_HEARTBEAT_INTERVAL_MS',
    'BRIDGE_WS_HEARTBEAT_TIMEOUT_MS',
    'BRIDGE_WS_RECONNECT_BACKOFF_MIN_MS',
    'BRIDGE_WS_RECONNECT_BACKOFF_MAX_MS',
    'BRIDGE_WS_RECONNECT_JITTER_MS',
]:
    require(symbol in CONTRACTS, f'missing shared reliability contract constant {symbol}')
    require(f'contracts.{symbol}' in BRIDGE, f'bridge should consume shared {symbol}')

# Bounded transient queue: no silent unbounded in-memory growth; callers receive
# an explicit backpressure result when the queue cannot accept more.
require('bridge_transit_queue_can_accept_locked :: proc' in BRIDGE, 'bounded transit queue helper missing')
require('len(bridge_transit_queue) >= contracts.BRIDGE_WS_MAX_TRANSIT_QUEUE_FRAMES' in BRIDGE, 'transit queue frame cap missing')
require('bridge_transit_queue_bytes_locked() + len(frame_text) > contracts.BRIDGE_WS_MAX_TRANSIT_QUEUE_BYTES' in BRIDGE, 'transit queue byte cap missing')
require('bridge_transit_queue_prune_locked()' in BRIDGE, 'transit queue TTL pruning missing')
require('return false, "backpressure"' in BRIDGE, 'bridge send should surface backpressure')
require('bridge_send_backpressure_json' in BRIDGE and 'BRIDGE_SEND_ACCEPTANCE_BACKPRESSURE' in CONTRACTS, 'loopback backpressure response missing')

# Chunk reliability: chunks are ACKed, senders retry within bounded attempts,
# and reassembly buffers are capped.
require('bridge_ws_handle_chunk_ack :: proc' in BRIDGE, 'chunk ACK handler missing')
require('bridge_wait_for_chunk_ack :: proc' in BRIDGE, 'chunk ACK wait helper missing')
require('attempt < contracts.BRIDGE_WS_CHUNK_MAX_SEND_ATTEMPTS' in BRIDGE, 'chunk retry attempt cap missing')
require('bridge_wait_for_chunk_ack(chunk_id, i, contracts.BRIDGE_WS_CHUNK_ACK_TIMEOUT_MS)' in BRIDGE, 'chunk ACK timeout missing')
require('if !acked do return false' in BRIDGE, 'missing chunk ACK must fail transport')
require('thread.run_with_poly_data(Bridge_WS_Request_Job' in BRIDGE, 'large request responses must be sent from worker while read loop observes ACKs')
require('total_bytes > contracts.BRIDGE_WS_MAX_REASSEMBLY_BYTES' in BRIDGE, 'reassembly byte cap missing')
require('chunk_count > contracts.BRIDGE_WS_MAX_CHUNK_COUNT' in BRIDGE, 'reassembly chunk-count cap missing')
require('chunk_count > total_bytes' in BRIDGE, 'impossible chunk metadata guard missing')
require('received_bytes + len(decoded_text) > bridge_reassemblies[idx].total_bytes' in BRIDGE, 'reassembly byte overflow guard missing')
require('len(bridge_reassemblies) >= contracts.BRIDGE_WS_MAX_REASSEMBLIES' in BRIDGE, 'reassembly count cap missing')
require('bridge_ws_chunk_ack_json' in BRIDGE, 'chunk ACK frame emission missing')

# Liveness/reconnect: both accepted and dialed sockets have heartbeat timeout;
# dialer reconnect uses bounded exponential backoff plus jitter.
require('bridge ws heartbeat timeout' in BRIDGE, 'heartbeat timeout logging/path missing')
require('contracts.BRIDGE_WS_HEARTBEAT_INTERVAL_MS' in BRIDGE and 'contracts.BRIDGE_WS_HEARTBEAT_TIMEOUT_MS' in BRIDGE, 'heartbeat constants not used')
require('BRIDGE_WS_RECONNECT_BACKOFF_MIN_MS' in CONTRACTS and 'BRIDGE_WS_RECONNECT_BACKOFF_MAX_MS' in CONTRACTS, 'reconnect backoff constants missing')
require('BRIDGE_WS_RECONNECT_JITTER_MS' in CONTRACTS and 'jitter_ms' in BRIDGE, 'reconnect jitter missing')
require('ws.send_text' not in BRIDGE, 'bridge must not bypass synchronized write_ws_text for dialed socket writes')
require('write_ws_text(conn.socket, bridge_ws_keepalive_json())' in BRIDGE, 'dialer keepalive must use synchronized bridge writer')

# The WS helper must support bridge-sized chunk wrapper frames without exposing
# chunks to daemon loopback callers.
require('buf: [131072]byte' in BRIDGE, 'bridge WS reader should support large chunk wrapper frames')
require('buf: [131072]byte' in WS, 'WS client reader should support large chunk wrapper frames')
require('if n > 65535 do return false' in WS, 'WS client writer should bound large frames')
require('if len(text) > 65535 do return false' in BRIDGE, 'bridge WS writer should bound large frames')

# Large opaque payloads must not be truncated by a single short TCP send/read.
# This protects 10 MiB artifact fetch-through while keeping chunking bridge-owned.
require('bridge_tcp_send_all :: proc' in BRIDGE, 'bridge HTTP/WS writes must use send-all helper')
require('return bridge_tcp_send_all(socket, frame)' in BRIDGE, 'bridge WS writer must send complete frames')
require('if len(body) > 0 do _ = bridge_tcp_send_all(client, transmute([]byte)body)' in BRIDGE, 'bridge loopback responses must send complete bodies')
require('tcp_send_all :: proc' in DAEMON_HTTP, 'daemon binary responses must use send-all helper')
require('if len(body) > 0 && !tcp_send_all(client, body) do return' in DAEMON_HTTP, 'daemon artifact responses must send complete binary bodies')
require('if len(response_body) < content_length do return {}, false' in HTTP_CLIENT, 'HTTP client must fail explicit truncation instead of accepting partial bodies')
require('ARTIFACT_FEDERATION_FETCH_TIMEOUT_MS :: 60000' in ARTIFACT_HTTP, 'large artifact fetch-through needs bounded large-payload timeout')
require('bridge_request(dest_daemon_id, contracts.BRIDGE_HTTP_METHOD_GET, path, "", federation_idempotency_key("artifact_fetch", server_daemon_id, resolved_artifact_id), ARTIFACT_FEDERATION_FETCH_TIMEOUT_MS)' in ARTIFACT_HTTP, 'artifact fetch-through must use large-payload bridge timeout without daemon-visible chunks')
require('artifact_resolve_content: remote artifact size mismatch' in ARTIFACT_HTTP, 'artifact cache path must log remote size mismatch')
require('artifact_resolve_content: remote artifact cache write failed' in ARTIFACT_HTTP, 'artifact cache path must log local write failure')

print('bridge_reliability_static: ok')
