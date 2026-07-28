#!/usr/bin/env python3
"""Regression: default conversation heading uses the user-named agent, not agt_* ids."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
THREAD = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
CONTENT = (ROOT / "src/hub/transport/http/content_handlers.odin").read_text(encoding="utf-8")
AGENT_SERVICE = (ROOT / "src/hub/service/agent/agent_service.odin").read_text(encoding="utf-8")
SIDEBAR = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('agent_name:= ""' not in CONTENT and 'agent_name:=""' in CONTENT and 'agent_name=agent.name' in CONTENT and '\\",\\"agent_name\\":\\"' in CONTENT, "/chats list must include agent_name")
require('agent_slug:=""' in CONTENT and 'agent_slug=agent.slug' in CONTENT and '\\",\\"agent_slug\\":\\"' in CONTENT, "/chats list must include agent_slug fallback")
require('agent_display_name_for_id' in AGENT_SERVICE and 'title := agent_display_name_for_id' in AGENT_SERVICE, "new instance conversations should be titled from agent display name")
require('if name := strings.trim_space(agent.name); name != "" do return name' in AGENT_SERVICE, "agent display helper should prefer user-given name")
require('function conversationDisplayTitle' in THREAD, "thread title helper missing")
require('conversationAgentLabel(conversation)' in THREAD, "thread should derive agent label from conversation JSON")
require('looksLikeInternalId(rawTitle)' in THREAD, "thread should treat agt_* title as generated fallback")
require('const title = conversationDisplayTitle(conversation, agentId, agentInstanceId, conversationId);' in THREAD, "thread heading must use display title helper")
require('const editableTitle = rawTitle && !looksLikeInternalId(rawTitle) ? rawTitle : title;' in THREAD and 'setTitleDraft(editableTitle)' in THREAD, "rename editor should not seed old agt_* fallback titles")
require('displayConversationTitle' in SIDEBAR and 'looksLikeInternalId(title)' in SIDEBAR, "sidebar already hides internal fallback titles")
require('conversationTitleLooksInternal' in APP and 'if (daemonTitle && !conversationTitleLooksInternal(daemonTitle)) return daemonTitle;' in APP, "legacy chat heading should also ignore generated fallback titles")

fn_match = re.search(r"function conversationDisplayTitle\([\s\S]+?\n\}", THREAD)
require(fn_match is not None, "conversationDisplayTitle body missing")
fn = fn_match.group(0)
require('return agentLabel || agentId || conversationId;' in fn, "internal/default title should fall back to agent label before ids")

print("PASS: conversation default heading uses user-named agent")
