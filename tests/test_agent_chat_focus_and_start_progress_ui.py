#!/usr/bin/env python3
"""Static regression checks for agent chat focus and start lifecycle progress UI."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


home_agents = re.search(r'function HomeRunningAgentsPanel[\s\S]+?function MergeDecisionCard', APP)
require(home_agents is not None, 'HomeRunningAgentsPanel block missing')
home = home_agents.group(0)
require('chatInputRef = useRef<HTMLTextAreaElement | null>(null)' in home, 'direct agent chat input ref missing')
require('chatInputRef.current?.focus()' in home, 'direct agent chat should focus input after selected agent changes')
require('[selectedAgentId]' in home, 'focus effect should depend on selected agent identity')
require('ref={chatInputRef}' in home and 'data-debug-id="home-running-agent-chat-input"' in home, 'chat textarea should be wired to focus ref and debug id')

agent_detail = re.search(r'function AgentDetailPage[\s\S]+?function MergeDecisionCard', APP)
require(agent_detail is not None, 'AgentDetailPage block missing')
detail = agent_detail.group(0)
require('const [startProgress, setStartProgress]' in detail, 'start progress state missing')
require('setStartProgress({ active: true, agentId: agent.id' in detail, 'start action should initialize progress before daemon request')
require("runAgentAction('start'" in detail, 'start button should use start action wrapper')
require("if (kind === 'start') setStartProgress" in detail, 'start request failures should mark start progress failed')
require('data-debug-id="agent-detail-start-progress"' in detail, 'start progress card debug id missing')
require('data-debug-id="agent-detail-start-progress-bar"' in detail, 'start progress bar debug id missing')
for step in ['request', 'launch', 'connect', 'ready']:
    require(f"key: '{step}'" in detail, f'start progress step {step} missing')
    require('data-debug-id={`agent-detail-start-step-${step.key}`}' in detail, 'start progress step debug id missing')
require('window.setInterval(() => onRefreshAgents?.(), 1000)' in detail, 'start progress should poll agent lifecycle updates')

print('AGENT CHAT FOCUS AND START PROGRESS UI TEST PASSED')
