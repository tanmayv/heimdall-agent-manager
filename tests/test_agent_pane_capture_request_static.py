#!/usr/bin/env python3
"""Static contract checks for user-requested agent pane capture."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def require(ok: bool, msg: str) -> None:
    if not ok:
        raise AssertionError(msg)


def function_body(text: str, marker: str, next_marker: str) -> str:
    start = text.index(marker)
    end = text.index(next_marker, start)
    return text[start:end]


def test_backend_contract_markers():
    domain = read("src/hub/domain/content.odin")
    repo = read("src/hub/repository/iface/content_repo.odin")
    sqlite_repo = read("src/hub/repository/sqlite/content_repo_sqlite.odin")
    migration = read("src/hub/repository/sqlite/migrations/017_chat_message_types.sql")
    handlers = read("src/hub/transport/http/content_handlers.odin")
    wiring = read("src/hub/app/wiring.odin")

    for marker in ["message_type", "message_status", "metadata_json"]:
        require(marker in domain, f"Chat_Message missing {marker}")
        require(marker in sqlite_repo, f"sqlite message repo missing {marker}")
        require(marker in migration, f"migration missing {marker}")
    require("Content_Update_Message_Proc" in repo and "content_update_message" in repo, "message update repository contract missing")
    require("/api/v1/chats/*/pane-capture" in wiring, "pane capture route not registered")
    require("request_pane_capture" in handlers and "pane_capture_handler" in handlers, "pane capture HTTP handler missing")
    require("bridge_supports_pane_capture" in read("src/hub/service/content/content_service.odin"), "Hub must fail closed when Bridge lacks pane capture support")


def test_bridge_wrapper_runtime_contract_markers():
    bridge = read("src/bridge/hub_runtime_client.odin")
    endpoint = read("src/bridge/wrapper_endpoint.odin")
    wrapper = read("src/wrapper/bridge_runtime.odin")
    tmux = read("src/lib/tmux/tmux.odin")
    hub_bridge = read("src/hub/transport/http/bridge_handlers.odin")

    require('type == "capture_agent_pane"' in bridge, "Bridge must handle capture_agent_pane runtime commands")
    require('bridge_runtime_features_json' in bridge and 'capture_agent_pane' in bridge, "Bridge must advertise capture_agent_pane capability")
    require('pane_capture_request' in bridge and 'bridge_pane_capture_push_json' in bridge, "Bridge must push pane_capture_request to wrapper")
    require('wrapper.pane_capture.result' in endpoint, "wrapper pane capture result method must be allowlisted")
    require('method == "wrapper.pane_capture.result"' in endpoint, "wrapper pane capture result handler missing")
    require('"pane_capture_result"' in hub_bridge, "Hub bridge WS loop must handle pane_capture_result")
    require("resize_pane_width" in tmux and '"resize-pane"' in tmux and '"-x"' in tmux, "tmux width resize helper missing")
    require("wrapper_bridge_handle_pane_capture_request" in wrapper, "wrapper pane capture push handler missing")
    require("wrapper_bridge_sanitize_capture" in wrapper, "wrapper capture sanitization missing")

    heartbeat = function_body(bridge, "bridge_hub_heartbeat_json :: proc", "bridge_runtime_expire_stale_locked")
    require("pane_capture" not in heartbeat and "output" not in heartbeat, "Bridge heartbeat must not carry pane capture payloads")


def test_ui_contract_markers():
    api = read("src/ui/api/endpoints/chats.ts")
    page = read("src/ui/components/chat/ConversationThreadPage.tsx")
    types = read("src/ui/components/chat/types.ts")
    registry = read("AGENTS.md")

    require("requestPaneCapture" in api and "/pane-capture" in api, "RTK pane capture mutation missing")
    require("messageType" in types and "messageStatus" in types and "metadata" in types, "ChatMessage typed metadata fields missing")
    require('data-debug-id="conversation-request-pane-btn"' in page, "request pane debug id missing")
    for marker in ["conversation-pane-capture-loading", "conversation-pane-capture-output", "conversation-pane-capture-error", "conversation-pane-capture-retry"]:
        require(marker in page, f"pane capture render marker missing: {marker}")
        require(marker in registry, f"debug registry missing {marker}")


if __name__ == "__main__":
    test_backend_contract_markers()
    test_bridge_wrapper_runtime_contract_markers()
    test_ui_contract_markers()
    print("PASS: agent pane capture static")
