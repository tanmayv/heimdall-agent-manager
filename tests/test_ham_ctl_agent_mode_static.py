#!/usr/bin/env python3
"""Static tests for ham-ctl agent mode (RTE2E-7).

Agent mode MUST talk only to the local Bridge endpoint over JSONL v1 using the
local agent token. It MUST NOT hold or send a Hub URL or Hub credential.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return Path(ROOT / path).read_text()


def require(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)


def main():
    ctl = read("src/ctl/main.odin")

    # --- dispatch wiring ----------------------------------------------------
    require("ctl_agent_mode(early_cmd[:], os.args)" in ctl,
            "early config-free dispatch must route 'agent' to agent mode")
    require('cmd[0] == "agent" || has_flag(os.args, "--agent-mode")' in ctl,
            "post-config dispatch must also route agent mode")

    # --- discovery: endpoint + local token only ----------------------------
    require('option_value(args, "--bridge-endpoint", "")' in ctl,
            "agent mode must discover endpoint via --bridge-endpoint")
    require('"HEIMDALL_BRIDGE_ENDPOINT"' in ctl,
            "agent mode must discover endpoint via HEIMDALL_BRIDGE_ENDPOINT env")
    require('option_value(args, "--agent-token", "")' in ctl,
            "agent mode must discover token via --agent-token")
    require('"HEIMDALL_AGENT_TOKEN"' in ctl,
            "agent mode must discover token via HEIMDALL_AGENT_TOKEN env")

    # --- NO Hub coupling ----------------------------------------------------
    # Agent mode must not read HEIMDALL_HUB_URL / HEIMDALL_USER_TOKEN.
    # (Those are used only by hub user mode.) Verify the agent_* discovery
    # helpers do not reference Hub URL/user-token env names.
    am_start = ctl.index("ctl_agent_mode :: proc")
    am_end = ctl.index("ctl_hub_request :: proc")
    agent_block = ctl[am_start:am_end]
    require("HEIMDALL_HUB_URL" not in agent_block,
            "agent mode block must not reference HEIMDALL_HUB_URL")
    require("HEIMDALL_USER_TOKEN" not in agent_block,
            "agent mode block must not reference HEIMDALL_USER_TOKEN")
    # No http.request* call inside agent mode (local endpoint only, not HTTP).
    require("http.request_with_headers_timeout" not in agent_block,
            "agent mode must not make Hub HTTP requests")
    require("http.post(" not in agent_block and "http.get(" not in agent_block,
            "agent mode must not use http.get/http.post (local JSONL only)")

    # --- JSONL v1 envelope --------------------------------------------------
    require('"v":1,"id":"ham-ctl-agent"' in ctl,
            "agent JSONL request must be v1 with a stable id")
    require('"method":"' in ctl and '"params":' in ctl,
            "agent JSONL request must carry method + params")
    require('"token":"' in ctl,
            "agent JSONL request must carry the local token")

    # --- transports: unix primary + tcp fallback ---------------------------
    require('strings.has_prefix(endpoint, "unix:")' in ctl,
            "agent client must support unix: transport (primary)")
    require('strings.has_prefix(endpoint, "tcp:")' in ctl,
            "agent client must support tcp: transport (fallback)")
    require("posix.socket(.UNIX, .STREAM)" in ctl,
            "agent unix client must open an AF_UNIX stream socket")

    # --- method surface -----------------------------------------------------
    methods = [
        "agent.chat.send_to_user",
        "agent.tasks.comment",
        "agent.tasks.status",
        "agent.tasks.vote",
        "agent.tasks.nudge",
        "agent.artifacts.create",
        "agent.memory.propose",
        "agent.context.get",
        "agent.start_success",
    ]
    for m in methods:
        require(m in ctl, f"agent mode must expose method {m}")

    # --- offline/relay error surface ---------------------------------------
    require("local Bridge endpoint is not reachable" in ctl,
            "agent mode must report a clear offline error when the endpoint is unreachable")

    print("PASS: ham-ctl agent mode static")


if __name__ == "__main__":
    main()
