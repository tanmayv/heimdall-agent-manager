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
    main_odin = read("src/ctl/main.odin")
    ctl = read("src/ctl/agent_mode.odin")

    # --- dispatch wiring (agent API v2) ------------------------------------
    require('cmd[0] == "agent" || has_flag(os.args, "--agent-mode")' in main_odin,
            "dispatch must route agent mode")
    # Agent-facing groups dispatch through agent mode without the `agent` prefix
    # when a Bridge agent context is present.
    for group in ("bridge", "agents", "task-chain", "task", "chat", "artifact", "memory", "context"):
        require(f'"{group}"' in main_odin,
                f"main dispatch must recognize the {group} group")

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
    require("HEIMDALL_HUB_URL" not in ctl,
            "agent mode must not reference HEIMDALL_HUB_URL")
    require("HEIMDALL_USER_TOKEN" not in ctl,
            "agent mode must not reference HEIMDALL_USER_TOKEN")
    require("http.request_with_headers_timeout" not in ctl,
            "agent mode must not make Hub HTTP requests (local JSONL only)")

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

    # --- method surface (agent API v2, flat names) -------------------------
    methods = [
        "agent.chat.send",
        "agent.chat.read",
        "agent.task.comment",
        "agent.task.status",
        "agent.task.vote",
        "agent.task.nudge",
        "agent.agents.new_instance",
        "agent.agents.instance_start",
        "agent.agents.instance_stop",
        "agent.agents.instance_restart",
        "agent.bridge.list",
        "agent.artifact.create",
        "agent.memory.propose",
        "agent.context.get",
        "agent.start_success",
    ]
    for m in methods:
        require(m in ctl, f"agent mode must expose method {m}")

    # --- removed redundant verbs (one way per action) ----------------------
    require("agent.chat.send_to_user" not in ctl,
            "chat send_to_user must be collapsed into chat.send")
    require("agent.tasks.comment" not in ctl,
            "legacy agent.tasks.* methods must be gone (now agent.task.*)")
    require("agent.instances.launch" not in ctl,
            "legacy agent.instances.launch must be gone (now agents.new_instance)")

    # --- offline/relay error surface ---------------------------------------
    require("local Bridge endpoint is not reachable" in ctl,
            "agent mode must report a clear offline error when the endpoint is unreachable")

    print("PASS: ham-ctl agent mode static")


if __name__ == "__main__":
    main()
