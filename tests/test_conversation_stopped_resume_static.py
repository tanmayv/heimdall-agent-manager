#!/usr/bin/env python3
"""Static regression for stopped conversation thread reopen/start (task-19f68a1d3dd).

A stopped conversation instance reports state=idle, startup_status=stopped,
connected=false. isAgentRunning previously treated state=='idle' as running,
so the conversation thread hid its Start/resume affordance after a stop. The
fix makes an explicitly stopped/offline+disconnected instance non-running so
`conversation-thread-start-btn` reappears for exact resume.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


body = re.search(r"export function isAgentRunning\(agent: any\): boolean \{([\s\S]+?)\n\}", APP)
require(body is not None, "isAgentRunning helper missing")
fn = body.group(1)

# Explicitly stopped/stopping instances must not be considered running.
require("startup === 'stopped' || startup === 'stopping'" in fn, "stopped/stopping startup must short-circuit to not-running")
# A mapped offline + disconnected instance must not be running.
require("mappedStatus === 'offline' && !agent.connected" in fn, "offline + disconnected instance must be non-running")
# Bare state=='idle' must no longer force running (only connected idle counts).
require("'idle'" not in re.search(r"return \[[^\]]*\]\.includes\(state\)", fn).group(0), "bare state=='idle' must not be treated as running")

# The thread page still exposes the exact-instance start affordance and stopped banner.
require('data-debug-id="conversation-thread-start-btn"' in APP, "conversation thread start button debug id missing")
require('This thread is stopped. Sending will start the conversation agent and preserve this history.' in APP, "stopped-thread send banner missing")
require("const live = isAgentRunning(agent) && !locallyStopped;" in APP, "conversation thread live state must derive from isAgentRunning")

print("PASS: conversation stopped resume static checks")
