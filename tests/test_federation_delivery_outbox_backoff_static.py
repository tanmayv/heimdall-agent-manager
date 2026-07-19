#!/usr/bin/env python3
"""Static regression for federation delivery outbox replay backoff.

Bad/stuck outbox rows should not replay hot forever, but healthy redelivery must
still remain transition/poll driven once a peer is linked again.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = (ROOT / 'src/daemon/federation_transport.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('FEDERATION_REPLAY_BACKOFF_MIN_MS :: i64(10 * 1000)' in TRANSPORT, 'minimum replay backoff constant missing')
require('FEDERATION_REPLAY_BACKOFF_MAX_MS :: i64(5 * 60 * 1000)' in TRANSPORT, 'maximum replay backoff cap missing')
require('FEDERATION_REPLAY_STUCK_ATTEMPTS :: 6' in TRANSPORT, 'stuck-attempt threshold missing')
require('federation_delivery_outbox_retry_backoff_ms :: proc(attempts: int) -> i64' in TRANSPORT, 'retry backoff helper missing')
require('for _ in 1..<attempts {' in TRANSPORT, 'retry backoff should scale by attempt count')
require('federation_delivery_outbox_retry_eligible :: proc(attempts: int, last_attempt_unix_ms, now_unix_ms: i64) -> bool' in TRANSPORT, 'retry eligibility helper missing')
require('_, dest_daemon_id, status, ok := federation_direct_peer_lookup_cached(peer_id, "")' in TRANSPORT, 'replay should use the current bridge projection without recursive re-hydration')
require('if !ok || status != PEER_STATUS_LINKED || dest_daemon_id == "" do return 0' in TRANSPORT, 'unlinked/unresolved peers must not consume replay attempts')
require('accepted := bridge_send(dest_daemon_id, route_kinds[i], payloads[i], idempotency_keys[i])' in TRANSPORT, 'replay should reuse the resolved destination daemon id when attempting bridge delivery')
require('SELECT route_kind, idempotency_key, payload, created_unix_ms, attempts, last_attempt_unix_ms' in TRANSPORT, 'replay query must load attempt state for throttling')
require('if !federation_delivery_outbox_retry_eligible(attempts[i], last_attempt_unix_ms[i], now) do continue' in TRANSPORT, 'backoff-ineligible head row must not block later eligible rows')
require('FEDERATION_OUTBOX_STUCK ts_unix_ms=%d peer_id=%s route_kind=%s idempotency_key=%s attempts=%d age_ms=%d last_attempt_unix_ms=%d backoff_ms=%d' in TRANSPORT, 'stuck row logging must surface actionable evidence')
require('if next_attempts >= FEDERATION_REPLAY_STUCK_ATTEMPTS {' in TRANSPORT, 'stuck threshold should gate log emission')
require('federation_delivery_outbox_log_stuck(peer_id, route_kinds[i], idempotency_keys[i], next_attempts, created_unix_ms[i], now, now, federation_delivery_outbox_retry_backoff_ms(next_attempts))' in TRANSPORT, 'stuck rows must be logged with persisted attempt metadata')
require('if next_attempts >= FEDERATION_REPLAY_STUCK_ATTEMPTS {\n\t\t\t\tfederation_delivery_outbox_log_stuck(peer_id, route_kinds[i], idempotency_keys[i], next_attempts, created_unix_ms[i], now, now, federation_delivery_outbox_retry_backoff_ms(next_attempts))\n\t\t\t\tcontinue\n\t\t\t}' in TRANSPORT, 'stuck rows must be skipped so later healthy rows can replay')

print('federation_delivery_outbox_backoff_static: ok')
