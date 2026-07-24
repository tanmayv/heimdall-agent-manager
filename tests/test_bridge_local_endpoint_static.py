#!/usr/bin/env python3
"""Static guard for Runtime E2E RTE2E-3 Bridge local endpoint boundary."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOKEN = ROOT / "src" / "bridge" / "agent_token_store.odin"
ENDPOINT = ROOT / "src" / "bridge" / "wrapper_endpoint.odin"
MAIN = ROOT / "src" / "bridge" / "main.odin"
HUB_WIRING = ROOT / "src" / "hub" / "app" / "wiring.odin"
HUB_AGENT_ACTIONS = ROOT / "src" / "hub" / "transport" / "http" / "agent_action_handlers.odin"
DOC = ROOT / "docs" / "plans" / "runtime-e2e-local-bridge-endpoint.md"
OLD_WRAPPER = ROOT / "src" / "wrapper"
OLD_CTL = ROOT / "src" / "ctl"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    token = read(TOKEN)
    endpoint = read(ENDPOINT)
    main = read(MAIN)
    hub_wiring = read(HUB_WIRING)
    hub_agent_actions = read(HUB_AGENT_ACTIONS)
    doc = read(DOC)

    for marker in [
        "Bridge_Local_Agent_Token_Record",
        "bridge_agent_token_issue",
        "bridge_agent_token_verify",
        "bridge_agent_token_rotate",
        "bridge_agent_token_invalidate",
        "token_hash",
        "sha1:",
        "instance_token: string, // Hub credential: Bridge-held only",
        "hlat_",
    ]:
        require(marker in token, f"missing local token-store marker: {marker}")

    for marker in [
        "Bridge_Local_Endpoint_Config",
        "unix_socket_path",
        "bridge_local_endpoint_prepare_unix_socket_path",
        "0600",
        "bridge_local_endpoint_start_unix",
        "posix.mode_t{.IRUSR, .IWUSR}",
        "bridge_local_endpoint_accept_unix_loop",
        "bridge_local_endpoint_start_loopback",
        "bridge_local_endpoint_handle_jsonl_line",
        "bridge_local_extract_json_string(line, \"id\"", "bridge_local_extract_json_string(line, \"token\"", "bridge_local_extract_json_string(line, \"method\"", "params",
        "bridge_local_method_allowed",
        "wrapper.startup.report", "wrapper.activity.report", "wrapper.liveness.ping", "wrapper.exited",
        "agent.chat.send_to_user", "agent.tasks.comment", "agent.tasks.status", "agent.tasks.vote", "agent.tasks.nudge",
        "agent.artifacts.create", "agent.memory.propose", "agent.context.get", "agent.start_success",
        "Bridge-held instance token is unavailable",
        "bridge_local_agent_relay_body",
        "Authorization", "Bearer ",
        "agent_instance_id",  # Bridge injects identity into relay body
    ]:
        require(marker in endpoint, f"missing local endpoint marker: {marker}")

    require("/api/v1/agent-actions/" in endpoint, "agent relay path mapping missing")
    require("/api/v1/agent-actions/chat/send-to-user" in hub_wiring and "agent_action_chat_send_to_user_handler" in hub_agent_actions and "agent_action_task_comment_handler" in hub_agent_actions, "Hub agent-action relay routes must exist")
    require("verify_instance_token" in hub_agent_actions and "hit_" in (ROOT / "src" / "hub" / "service" / "agent" / "agent_service.odin").read_text(encoding="utf-8"), "Hub must verify instance bearer tokens for agent actions")
    require("send_agent_message" in hub_agent_actions and "agent_to_user" in (ROOT / "src" / "hub" / "service" / "content" / "content_service.odin").read_text(encoding="utf-8"), "agent.chat.send_to_user must be backed by Hub chat persistence")
    require("comment_task" in hub_agent_actions and "taskchain_save_comment" in (ROOT / "src" / "hub" / "service" / "taskchain" / "taskchain_service.odin").read_text(encoding="utf-8"), "agent.tasks.comment must persist a Hub task comment")
    require("bridge_local_spoofable_params" in endpoint and "sender_agent_instance_id" in endpoint and "owner_user_id" in endpoint, "local params must reject spoofable identity fields")
    require("--local-endpoint-port" in main and "--local-run-dir" in main and "socket_mode" in main, "bridge CLI must expose local endpoint smoke flags")
    require("bridge_agent_token_store_init" in main, "token store must initialize in bridge runtime")
    require("Transport implementation" in doc and "Unix socket" in doc and "owner read/write (`0600`)" in doc, "Unix + loopback transport implementation must be documented")

    wrapper_files = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_WRAPPER.rglob("*.odin"))
    ctl_files = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in OLD_CTL.rglob("*.odin"))
    require("HEIMDALL_BRIDGE_ENDPOINT" not in wrapper_files, "old src/wrapper must remain unmigrated")
    require("hlat_" not in ctl_files, "old src/ctl must remain unmigrated to local agent tokens in this task")

    print("PASS: bridge local endpoint static")


if __name__ == "__main__":
    main()
