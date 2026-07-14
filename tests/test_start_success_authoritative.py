#!/usr/bin/env python3
"""Regression checks that only agent start-success marks startup ready."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = (ROOT / 'src/wrapper/main.odin').read_text(encoding='utf-8')
REGISTRY = (ROOT / 'src/daemon/registry.odin').read_text(encoding='utf-8')
LIFECYCLE = (ROOT / 'src/daemon/lifecycle.odin').read_text(encoding='utf-8')
RUNTIME = (ROOT / 'src/daemon/agent_runtime_tracker.odin').read_text(encoding='utf-8')
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


wrapper_launch_block = re.search(r'tmux_pane.*?startup_report_begin :=', WRAPPER, re.S)
require(wrapper_launch_block is not None, 'wrapper launch startup block missing')
block = wrapper_launch_block.group(0)
require('startup_status := "starting"' in block, 'wrapper should default launched agents to starting')
require('startup_reason_code := "awaiting_start_success"' in block, 'wrapper should wait for explicit start-success')
require('Startup detection disabled; assuming ready' not in block, 'wrapper must not assume ready when startup detection is disabled')
require('startup_status := "ready"' not in block and 'startup_reason_code := "launch_success"' not in block, 'wrapper must not default to ready/launch_success')

require('incoming_status == "ready" && incoming_reason != "start_success"' in REGISTRY, 'heartbeat startup sync must reject non-start_success ready')
require('incoming_status = "starting"' in REGISTRY and 'awaiting_start_success' in REGISTRY, 'heartbeat ready normalization should keep agent starting')
require('status == "ready" && reason_code != "start_success"' in LIFECYCLE, 'startup report handler must reject non-start_success ready')
require('status = "starting"' in LIFECYCLE and 'waiting for agent start-success RPC' in LIFECYCLE, 'startup report ready normalization should keep agent starting')
require('registry_update_startup(agent_instance_id, "ready", "start_success"' in RUNTIME, 'start-success RPC must be the path that marks ready')

for snippet in [
    "const coordinatorReady = Boolean(coordinator && reason === 'start_success');",
    "const launchReady = Boolean(launchProgressId && launchReason === 'start_success');",
    "const startReady = Boolean(startProgress?.active && startReason === 'start_success');",
    "const agentStartDone = Boolean(startProgress?.active && !startFailed && startReady);",
    'Tracking start lifecycle events until agent calls start-success.',
]:
    require(snippet in APP, f'UI must require explicit start-success: missing {snippet}')

print('START SUCCESS AUTHORITATIVE TEST PASSED')
