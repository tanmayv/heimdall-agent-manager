package contracts

// Keep APP_VERSION in sync with flake.nix appVersion for releases.
APP_VERSION :: #config(HAM_APP_VERSION, "0.1.0")
GIT_COMMIT :: #config(HAM_GIT_COMMIT, "")
BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, "")
PROTOCOL_VERSION :: 1

ROUTE_HEALTH :: "/health"
ROUTE_REGISTER :: "/register"
ROUTE_RECONNECT :: "/reconnect"
ROUTE_HEARTBEAT :: "/heartbeat"
ROUTE_WS_PREFIX :: "/ws"
ROUTE_AGENT_RPC :: "/agent-rpc"
ROUTE_AGENTS_START :: "/agents/start"
