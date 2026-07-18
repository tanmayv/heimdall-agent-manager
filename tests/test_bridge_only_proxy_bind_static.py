from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')
TRANSPORT = (ROOT / 'src/daemon/federation_transport.odin').read_text(encoding='utf-8')
MESSAGE = (ROOT / 'src/daemon/message_service.odin').read_text(encoding='utf-8')
TASK_HTTP = (ROOT / 'src/daemon/task_http.odin').read_text(encoding='utf-8')
ARTIFACT_HTTP = (ROOT / 'src/daemon/artifact_http.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


# Bridge-only daemon setups have no daemon-owned peer_link_records from config.
# Proxy bind and outbound direct routing must resolve peer identity from the
# secret-free bridge reachability projection instead of requiring peer_url/token.
require('federation_direct_peer_lookup :: proc' in PEERS, 'bridge projection peer lookup helper missing')
lookup = re.search(r'federation_direct_peer_lookup :: proc\(.*?\) -> .*? \{(.*?)\n\}', PEERS, re.S)
require(lookup is not None, 'could not inspect federation_direct_peer_lookup')
lookup_body = lookup.group(1)
require('reachable_daemon_hydrate_from_bridge()' in lookup_body, 'lookup must hydrate from bridge reachability')
require('reachable_daemon_records' in lookup_body, 'lookup must use reachability projection')
require('peer_link_find(trimmed_peer_id)' in PEERS, 'lookup may keep legacy fallback only after projection')
require('if trimmed_origin != "" {' in PEERS, 'lookup must prefer origin_daemon_id when supplied')
require('if trimmed_peer_id != "" && rec.peer_id != trimmed_peer_id && rec.daemon_id != trimmed_peer_id' in PEERS, 'lookup must reject mismatched peer_id/origin_daemon_id')
require('return "", "", "", false' in PEERS, 'lookup must fail closed on mismatched/missing projection identity')

bind = re.search(r'federation_remote_proxy_bind :: proc\(.*?\) -> .*? \{(.*?)\n\}', PEERS, re.S)
require(bind is not None, 'could not inspect federation_remote_proxy_bind')
bind_body = bind.group(1)
require('federation_direct_peer_lookup(peer_id, origin_daemon_id)' in bind_body, 'proxy bind must use bridge projection lookup')
require('peer_link_find(peer_id)' not in bind_body, 'proxy bind must not require legacy peer_link_find')
require('resolved_peer_id' in bind_body and 'bridge_daemon_id' in bind_body, 'proxy bind must preserve resolved peer/daemon identity')
require('AGENT_KIND_REMOTE_PROXY' in bind_body, 'proxy bind must continue creating remote_proxy agents')
require('peer_url' not in bind_body and 'peer_token' not in bind_body, 'proxy bind must not use daemon peer URL/token')

# Outbound direct federation helpers should not depend on legacy peer links in
# bridge-only mode; they must resolve destination daemon ids via projection.
for proc_name in [
    'federation_forward_transport_accepted',
    'federation_forward_start',
    'federation_remote_message_body_fetch',
    'federation_remote_get',
    'federation_remote_post_callback',
]:
    m = re.search(rf'{proc_name} :: proc\(.*?\) .*?\{{(.*?)\n\}}', TRANSPORT, re.S)
    require(m is not None, f'could not inspect {proc_name}')
    body = m.group(1)
    require('federation_direct_peer_lookup(' in body, f'{proc_name} must use bridge projection lookup')
    require('peer_link_find(' not in body, f'{proc_name} must not require legacy peer_link_find')
    require('peer_url' not in body and 'peer_token' not in body, f'{proc_name} must not use peer URL/token')

# Remaining direct Phase 1 callbacks/fetch-through paths must use the same
# bridge-only lookup instead of legacy peer links.
require('federation_direct_peer_lookup(remote_rec.owner_peer_id, remote_rec.owner_daemon_id)' in MESSAGE, 'message read receipt callback must use bridge projection lookup')
require('peer_link_find(remote_rec.owner_peer_id)' not in MESSAGE, 'message read receipt callback must not require legacy peer link')
require('federation_direct_peer_lookup(work.owner_peer_id, work.origin_daemon_id)' in TASK_HTTP, 'remote task callbacks must use bridge projection lookup')
require('peer_link_find(work.owner_peer_id)' not in TASK_HTTP, 'remote task callbacks must not require legacy peer link')
require('federation_direct_peer_lookup(resolved_route_peer_id, resolved_origin_daemon_id)' in ARTIFACT_HTTP, 'artifact fetch-through must use bridge projection lookup')
require('peer_link_find_by_daemon_id(resolved_origin_daemon_id)' not in ARTIFACT_HTTP, 'artifact fetch-through must not require legacy daemon-id peer link')
require('peer_link_find(resolved_route_peer_id)' not in ARTIFACT_HTTP, 'artifact fetch-through must not require legacy peer link')

# Bridge source authentication context should also map daemon ids through the
# bridge projection so inbound callbacks from clean bridge-only peers scope to
# the correct remote peer id.
require('federation_peer_id_for_bridge_source :: proc' in TRANSPORT, 'bridge source lookup missing')
source = re.search(r'federation_peer_id_for_bridge_source :: proc\(.*?\) -> .*? \{(.*?)\n\}', TRANSPORT, re.S)
require(source is not None, 'could not inspect federation_peer_id_for_bridge_source')
require('federation_direct_peer_lookup(trimmed_daemon_id, trimmed_daemon_id)' in source.group(1), 'bridge source lookup must use projection')

print('bridge_only_proxy_bind_static: ok')
