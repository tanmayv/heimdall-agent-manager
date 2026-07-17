from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
HTTP = (ROOT / 'src/lib/http_client/http_client.odin').read_text(encoding='utf-8')
ARTIFACT_HTTP = (ROOT / 'src/daemon/artifact_http.odin').read_text(encoding='utf-8')
TRANSPORT = (ROOT / 'src/daemon/federation_transport.odin').read_text(encoding='utf-8')
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')
ROUTER = (ROOT / 'src/daemon/rest_router.odin').read_text(encoding='utf-8')
MERGE = (ROOT / 'src/daemon/merge_lifecycle.odin').read_text(encoding='utf-8')
ATTN = (ROOT / 'src/ui/store/attentionSlice.ts').read_text(encoding='utf-8')
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAIL: {msg}')
        sys.exit(1)


require('request_with_timeout :: proc' in HTTP, 'http_client timeout wrapper missing')
require('get_with_timeout :: proc' in HTTP and 'post_with_timeout :: proc' in HTTP, 'timeout-aware get/post helpers missing')
require('dial_tcp_with_timeout :: proc' in HTTP and 'posix.connect' in HTTP and 'posix.poll' in HTTP, 'timeout wrapper must bound the dial/connect phase')
require('resolve_host_via_command :: proc' in HTTP and 'os.process_wait(process, time.Duration(timeout_ms) * time.Millisecond)' in HTTP, 'timeout wrapper must bound hostname resolution too')
require('net.set_option(socket, .Send_Timeout, timeout)' in HTTP and 'net.set_option(socket, .Receive_Timeout, timeout)' in HTTP, 'timeout wrapper must use socket-level I/O timeouts instead of detached worker threads')
require('thread.run_with_poly_data' not in HTTP and 'net.resolve(fmt.tprintf("%s:%d", host, port))' in HTTP, 'unsafe detached worker timeout implementation should be removed while preserving blocking fallback resolution')
require('FEDERATION_HTTP_TIMEOUT_MS :: 5000' in TRANSPORT, 'federation timeout constant missing')
require('http.post_with_timeout' in TRANSPORT and 'http.get_with_timeout' in TRANSPORT, 'federation transport must use timeout-aware http helpers')
require('http.get_with_timeout(rec.peer_url, "/health", FEDERATION_HTTP_TIMEOUT_MS)' in PEERS, 'peer probing must use bounded timeout')
require('peer_link_find_by_daemon_id :: proc' in PEERS, 'peer lookup by daemon_id missing for artifact fetch-through')

require('ARTIFACT_ORIGIN_FEDERATION_REMOTE :: "federation_remote"' in ARTIFACT_HTTP, 'remote artifact origin kind missing')
require('federation_artifact_fetch_through :: proc' in ARTIFACT_HTTP, 'artifact fetch-through helper missing')
require('artifact_federation_self_contained_eligible :: proc' in ARTIFACT_HTTP, 'artifact self-contained federation gate missing')
require('artifact_federation_reference_upsert :: proc' in ARTIFACT_HTTP, 'remote artifact reference upsert helper missing')
require('handle_get_federation_artifact_content :: proc' in ARTIFACT_HTTP, 'peer-authenticated federation artifact handler missing')
require('artifact_resolve_content :: proc' in ARTIFACT_HTTP, 'local artifact content resolver must fetch-through remote references')
require('artifact_ref' in TRANSPORT and 'server_daemon_id' in TRANSPORT, 'comment callbacks must carry remote artifact refs owned by the reviewer daemon')

for snippet in [
    'ctx.segments[1] == "artifacts" && ctx.method == "GET"',
    'handle_get_federation_artifact_content(client, ctx.segments[2], ctx)',
]:
    require(snippet in ROUTER, f'missing federation artifact route: {snippet}')

require('attention_federation_peer_blocks_json_items :: proc' in MERGE, 'attention must derive federation peer blocked items')
require('"kind":"federation_peer_block"' in MERGE, 'blocked attention item kind missing')
require('peer_rec.status != PEER_STATUS_UNREACHABLE' in MERGE, 'attention should only surface unreachable federation reviewer gates')
require('FederationPeerBlock' in ATTN and 'federationPeerBlocksById' in ATTN and 'federationPeerBlockIds' in ATTN, 'attention slice missing federation peer block state')
require('attention-card-federation_peer_block-' in APP, 'attention UI must render federation peer blocked cards')
require('action-remove-reviewer' in APP, 'attention UI must expose remove reviewer unblock action')

print('federation_phase45_static: ok')
