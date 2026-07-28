#!/usr/bin/env python3
"""Regression guard: live idle/running conversation runtimes show Stop, not Start."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
THREAD = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
LIVENESS = (ROOT / "src/ui/api/agentLiveness.ts").read_text(encoding="utf-8")
CATALOG = (ROOT / "src/ui/api/agentCatalog.ts").read_text(encoding="utf-8")
CONTENT_HANDLERS = (ROOT / "src/hub/transport/http/content_handlers.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


body = re.search(r"function runtimeNeedsStart\(status: string\): boolean \{([\s\S]+?)\n\}", THREAD)
require(body is not None, "runtimeNeedsStart helper missing")
fn = body.group(1)
require("normalized === 'idle'" not in fn, "idle runtime must not need Start")
require("normalized === 'stopped'" in fn and "normalized === 'failed'" in fn and "normalized === 'unreachable'" in fn, "only stopped/error runtimes should need Start")
require("conversationRuntimeStatus" in THREAD and "instance?.runtime_status || instance?.runtimeStatus || conversationRuntimeStatus" in THREAD, "conversation runtime_status should be fallback while instance fetch loads")
require("runtimeStopping" in THREAD and "disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping}" in THREAD, "stopping runtime should not offer another stop/start click")
require("needsStart ? 'conversation-thread-start-btn' : 'conversation-thread-stop-btn'" in THREAD, "start/stop debug id should derive from needsStart")
require("if (needsStart) await restartInstance" in THREAD and "else await stopInstance" in THREAD, "Stop branch must call stopInstance when runtime is live")

require("runtimeStatus" in LIVENESS and "'running', 'idle', 'busy', 'stopping'" in LIVENESS, "agent liveness must treat Bridge runtime live states as live")
require("runtimeStatus" in CATALOG and "runtimeStatus === 'idle'" in CATALOG and "status = 'idle'" in CATALOG, "agent catalog must map idle runtime as live idle, not offline")
require("restart_stopped_conversation_instance" in CONTENT_HANDLERS, "send path should restart only stopped/error conversation instances")
require('inst.runtime_status=="idle"' not in CONTENT_HANDLERS, "sending to a live idle agent must not relaunch it")

print("PASS: conversation runtime start/stop treats idle as live")
