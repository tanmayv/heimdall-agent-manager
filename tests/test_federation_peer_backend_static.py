from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CONFIG = (ROOT / "src/lib/config/config.odin").read_text(encoding="utf-8")
SERVER = (ROOT / "src/daemon/server.odin").read_text(encoding="utf-8")
ROUTER = (ROOT / "src/daemon/rest_router.odin").read_text(encoding="utf-8")
FED = (ROOT / "src/daemon/federation_peers.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str):
    if not condition:
        print(f"FAIL: {message}")
        sys.exit(1)


require("Peer_Config :: struct" in CONFIG, "config must define Peer_Config")
require("federation_advertised_agent_instance_ids: []string" in CONFIG, "config must define explicit advertised-agent allowlist")
require("if line == \"[[peer]]\"" in CONFIG, "config parser must recognize [[peer]] sections")
require("parse_peer_key(current_peer_index, key, value, &cfg.daemon)" in CONFIG, "config parser must dispatch peer keys")
require('case "federation_advertised_agent_instance_ids":' in CONFIG, "config parser must parse advertised-agent allowlist")
require("peer_link_store_init(server_data_dir, cfg.daemon.peers[:])" in SERVER, "server startup must hydrate peer links")

for snippet in [
    'ctx.segments[0] == "federation" && ctx.segments[1] == "agents"',
    'ctx.segments[0] == "federation" && ctx.segments[1] == "peers"',
    'ctx.segments[2] == "link"',
    'ctx.segments[2] == "reconnect"',
    'ctx.segments[2] == "remove"',
    'ctx.segments[3] == "agents"',
]:
    require(snippet in ROUTER, f"missing federation route snippet: {snippet}")

match = re.search(r"federation_peer_record_json :: proc\(builder: \^strings\.Builder, rec: Peer_Link_Record\) \{(.*?)\n\}", FED, re.S)
require(match is not None, "federation_peer_record_json function missing")
require("peer_token" not in match.group(1), "peer list JSON must redact peer_token")
require("federation_agent_is_advertised :: proc" in FED, "federation must gate results behind explicit advertisement allowlist")
require("federation_agent_is_advertised(rec.agent_instance_id)" in FED, "federation agent listing must filter by explicit allowlist")
require('peer_token := query_param_value(ctx.query, "peer_token")' in FED, "federation agents endpoint must read peer_token from query")
require('peer_daemon_id := query_param_value(ctx.query, "peer_daemon_id")' in FED, "federation agents endpoint must read caller daemon id from query")
require("peer_link_validate_request(peer_token, peer_daemon_id)" in FED, "federation agents endpoint must validate configured peer + token")
require('peer not configured or token mismatch' in FED, "federation endpoint must reject unknown peers")
require('/federation/agents?peer_token=%s&peer_daemon_id=%s' in FED, "peer agent fetches must include caller daemon id")
require("rest_authorize_user(client, ctx)" in FED, "peer management endpoints must require user/operator auth")
require("federation_advertised_agents_json()" in FED, "federation agents endpoint must serve advertised agents")

print("federation_peer_backend_static: ok")
