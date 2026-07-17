#!/usr/bin/env python3
"""Source-level regression that the Needs attention surface wires all four card
kinds, exposes the chat-approval reply/dismiss controls, and keeps state in the
new attention slice/WS handler.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/ui/components/App.tsx"
SLICE = ROOT / "src/ui/store/attentionSlice.ts"
STORE = ROOT / "src/ui/store/store.ts"
API = ROOT / "src/ui/api/daemonApi.ts"
WS = ROOT / "src/ui/api/wsInvalidation.ts"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    app = APP.read_text()
    slice_src = SLICE.read_text()
    store = STORE.read_text()
    api = API.read_text()
    ws = WS.read_text()

    require("attentionReducer" in store and "attention: attentionReducer" in store, "attention slice not registered in store")
    require("listPendingChatApprovals" in api and "answerChatApproval" in api and "dismissChatApproval" in api, "daemon API must expose chat-approval endpoints")

    for name in ["refreshChatApprovals", "answerChatApproval", "dismissChatApproval", "chatApprovalEventReceived", "tickChatApprovalExpiry"]:
        require(name in slice_src, f"attention slice missing {name}")
    require("state.chatApprovalIds = kept" in slice_src, "expiry tick must prune expired ids")

    require(
        "if (payload?.type === 'chat_approval')" in app or
        "if (payload?.type === 'chat_approval')" in ws or
        "case 'chat_approval':" in ws,
        "UI must handle chat_approval WS events",
    )
    require("dispatch(refreshChatApprovals())" in app, "attention surface must refresh chat approvals when opened")
    require("dispatch(refreshMemory())" in app, "attention surface must refresh memory when opened")
    require("dispatch(tickChatApprovalExpiry())" in app, "attention surface must periodically prune expired cards")

    require("function AttentionSurface(" in app, "AttentionSurface component missing")
    require("function ChatApprovalCard(" in app, "ChatApprovalCard component missing")
    require("attention-surface" in app, "AttentionSurface data-debug-id missing")
    require("attention-filter-${k.key}-btn" in app, "attention filter chips missing")
    for kind in ["chat_approval", "task_approval", "chain_merge", "memory"]:
        require(f"attention-card-{kind}-" in app, f"card renderer for {kind} missing")

    require("attention-empty" in app, "empty-state marker missing")
    require("humanTimeLeft" in app, "chat approval countdown helper missing")
    require("Dismiss silently" in app and "Dismiss and notify agent" in app, "chat approval must expose silent + notify dismiss options")
    require("attention-card-chat_approval" in app and "action-reply-" in app, "chat approval suggested replies must render")
    require("attention-card-chat_approval" in app and "action-freeform-send" in app, "chat approval must expose free-form send when free_form=true")

    # Badge count now includes actionable chat approvals, memory proposals, merges
    require("chatApprovalsById" in app and "kind !== 'multi_question'" in app, "badge count must include actionable chat approvals and exclude inline multi_question prompts")
    require("pendingMemoryIds" in app, "badge count must include pending memory proposals")
    require("mergeReviewingChains" in app, "badge count must include reviewing chains")

    # Badge count must match what the surface actually renders
    require("function isUserActionableTask" in app, "shared user-actionable task predicate missing")
    require("Object.values(tasksById).filter(isUserActionableTask)" in app, "badge count must use the shared predicate")
    require("Object.values(tasksById || {}).filter(isUserActionableTask)" in app, "attention surface must reuse the shared predicate")

    print("NEEDS ATTENTION UI TEST PASSED")


if __name__ == "__main__":
    main()
