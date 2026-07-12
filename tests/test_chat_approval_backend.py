#!/usr/bin/env python3
"""Source-level checks for chat_approvals backend wiring.

These do not spin up the daemon; they verify the code paths so we catch
accidental regressions to the plan/contract:
- durable table exists and has all required columns
- approval-shaped send_to_user resolves/infers chain_id before falling back to rejection
- terminal transitions and supersede + sweeper are wired
- endpoints are registered in the REST router
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "src/daemon/chat_approval_db.odin"
SERVICE = ROOT / "src/daemon/chat_approval_service.odin"
HTTP = ROOT / "src/daemon/chat_approval_http.odin"
AGENT_RPC = ROOT / "src/daemon/agent_rpc.odin"
CHAT_HTTP = ROOT / "src/daemon/chat_http.odin"
CHAT_STORE = ROOT / "src/daemon/chat_store.odin"
ROUTER = ROOT / "src/daemon/rest_router.odin"
SCHED = ROOT / "src/daemon/task_nudge_scheduler.odin"
TASK_SERVICE = ROOT / "src/daemon/task_service.odin"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    db = DB.read_text()
    service = SERVICE.read_text()
    http = HTTP.read_text()
    agent_rpc = AGENT_RPC.read_text()
    chat_http = CHAT_HTTP.read_text()
    chat_store = CHAT_STORE.read_text()
    router = ROUTER.read_text()
    sched = SCHED.read_text()

    # --- Durable schema
    for col in [
        "approval_id TEXT PRIMARY KEY",
        "message_id TEXT NOT NULL",
        "chain_id TEXT NOT NULL",
        "user_id TEXT NOT NULL",
        "agent_instance_id TEXT NOT NULL",
        "kind TEXT NOT NULL",
        "expires_at_unix_ms INTEGER NOT NULL",
        "state TEXT NOT NULL",
        "superseded_by_message_id TEXT NOT NULL",
    ]:
        require(col in db, f"chat_approvals schema missing column: {col}")

    require("chat_approval_db_init :: proc" in db, "db init proc missing")
    require("chat_approval_db_terminal_transition :: proc" in db, "terminal transition proc missing")
    require("chat_approval_db_list_open_for_user :: proc" in db, "list open for user proc missing")
    require("chat_approval_db_list_open_for_chain :: proc" in db, "list open for chain proc missing")
    require("chat_approval_db_list_expired :: proc" in db, "list expired proc missing")

    # --- Service
    require("chat_approval_detect_payload :: proc" in service, "payload detection missing")
    for kind in ["smart_answer", "questions", "multi_question", "approval_request"]:
        require(f'kind != "{kind}"' in service or f'"{kind}"' in service, f"kind {kind} not recognized")
    require("CHAT_APPROVAL_DEFAULT_TTL_MS" in service, "default TTL constant missing")
    require("chat_approval_service_record :: proc" in service, "record insert helper missing")
    require("chat_approval_service_terminal :: proc" in service, "terminal helper missing")
    for target in ["answered", "dismissed", "cancelled", "superseded", "expired"]:
        require(f'"{target}"' in service, f"terminal target {target} not handled")
    require("chat_approval_ws_emit" in service, "WS emit missing")
    for evt in [
        "chat_approval_answered",
        "chat_approval_dismissed",
        "chat_approval_cancelled",
        "chat_approval_superseded",
        "chat_approval_expired",
    ]:
        require(evt in service, f"WS event {evt} missing")
    require("chat_approval_sweep_expired :: proc" in service, "expiry sweeper missing")
    require("chat_approval_supersede_for_chain :: proc" in service, "supersede helper missing")

    # --- send_to_user detection + chain_id inference/enforcement
    require("chat_approval_detect_payload" in agent_rpc, "send_to_user must detect approval payloads")
    require("agent_rpc_infer_reply_chain_id" in agent_rpc, "send_to_user must infer chain_id from sender context")
    require(
        agent_rpc.find("agent_rpc_infer_reply_chain_id") < agent_rpc.find("chat_approval_detect_payload"),
        "send_to_user must infer chain_id before validating approval-shaped payloads",
    )
    require('chain_id_required_for_approval' in agent_rpc, "send_to_user must reject approval-shaped payload when chain_id cannot be resolved")
    require('chat_approval_service_record' in agent_rpc, "send_to_user must persist approval record on match")
    require('send_to_user did not create an approval record' in agent_rpc, "send_to_user must fail loudly if approval persistence fails")

    # --- Supersede on user->coordinator chat + fmt import
    require("chat_approval_supersede_for_chain(chain_id, message_body" in chat_http, "user->coordinator send must supersede open approvals")
    require('import "core:fmt"' in chat_http, "chat_http must import fmt for supersede count formatting")

    # --- init hook
    require("chat_approval_db_init()" in chat_store, "chat_store_init must call chat_approval_db_init")

    # --- Periodic sweeper
    require("chat_approval_sweep_expired()" in sched, "scheduler tick must sweep expired approvals")

    # --- HTTP endpoints
    for handler in [
        "handle_chat_approvals_pending",
        "handle_chat_approvals_answer",
        "handle_chat_approvals_dismiss",
        "handle_chat_approvals_cancel",
    ]:
        require(handler + " :: proc" in http, f"HTTP handler {handler} missing")
        require(handler in router, f"router does not wire {handler}")

    # --- Terminal state constraint (only one)
    require(re.search(r'if rec\.state != "open" do return', db), "terminal transition must be idempotent (only open -> terminal)")

    # --- Answer path posts a user_to_agent reply on the same chain
    require('chat_store_append_message_with_chain(rec.user_id, rec.agent_instance_id, "user_to_agent"' in http, "answer must send the reply as a normal user_to_agent chat message on the chain")

    # --- Dismiss must not send unless notify=true
    require('notify := extract_json_bool(body, "notify", false)' in http, "dismiss must default notify=false")
    require('User dismissed your approval request.' in http, "dismiss must have optional notification body when notify=true")

    # --- Cancel is restricted to sending agent token
    require('registry_agent_instance_for_token(ctx.token)' in http, "cancel must resolve agent identity")
    require('approval belongs to another agent' in http, "cancel must reject other agents")

    # --- Task service integration
    task_service = TASK_SERVICE.read_text()
    require('task_cancel_open_user_proxy_approvals :: proc' in task_service, "task service must expose cancel helper for user_proxy approvals")
    require('chat_approval_detect_payload(body)' in task_service, "user_proxy review card must be persisted as durable approval")
    require('task_cancel_open_user_proxy_approvals(cmd.task_id, state.chain_id)' in task_service, "leaving review_ready via status change must cancel approvals")
    require('task_cancel_open_user_proxy_approvals(cmd.task_id, cmd.chain_id)' in task_service, "review vote path must cancel approvals when task leaves review_ready")

    print("CHAT APPROVAL BACKEND TEST PASSED")


if __name__ == "__main__":
    main()
