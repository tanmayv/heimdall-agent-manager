#!/usr/bin/env python3
"""Source-level regression for multi_question chat approval support."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SVC = ROOT / "src/daemon/chat_approval_service.odin"
HTTP = ROOT / "src/daemon/chat_approval_http.odin"
SLICE = ROOT / "src/ui/store/attentionSlice.ts"
APP = ROOT / "src/ui/components/App.tsx"


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


def main() -> None:
    svc = SVC.read_text()
    http = HTTP.read_text()
    slice_src = SLICE.read_text()
    app = APP.read_text()

    require('"multi_question"' in svc and 'kind != "multi_question"' in svc, "backend must recognize multi_question payloads")
    require('chat_approval_extract_raw_json_value(trimmed, "questions")' in svc, "backend must persist multi_question questions array")
    require('res.free_form = free_form || kind == "questions" || kind == "multi_question"' in svc, "multi_question answers must be accepted as structured free-form replies")
    require('rec.state != "open"' in http and 'approval is no longer open' in http, "answer endpoint must reject reused cards")
    require('expires_at_unix_ms <= router_now_unix_ms()' in http, "answer endpoint must reject expired approvals")

    require('parseMultiQuestions' in slice_src and 'multiQuestions:' in slice_src, "UI slice must parse multi_question questions")
    require("kind === 'multi_question' ? [] : parseSuggestedReplies" in slice_src, "multi_question should render as questions, not flat replies")
    require("approval.kind === 'multi_question'" in app and 'action-multi-question-send' in app, "Needs attention must render multi_question answer form")
    require('answeredReply' in app and 'This card is disabled' in app, "Needs attention approval cards must mark/disable after answer")
    require('parseCoordinatorActionPayload' in app and "parsed.type === 'multi_question'" in app, "coordinator chat must render multi_question cards")
    require('usedActionCards' in app and 'Answers sent.' in app, "coordinator smart/multi cards must disable after use")

    print("MULTI QUESTION CHAT APPROVAL TEST PASSED")


if __name__ == "__main__":
    main()
