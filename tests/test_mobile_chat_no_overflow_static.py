#!/usr/bin/env python3
"""Static checks for mobile chat no-zoom/no-horizontal-overflow styling."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THREAD = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
LIST = (ROOT / "src/ui/components/chat/ChatMessageList.tsx").read_text(encoding="utf-8")
MARKDOWN = (ROOT / "src/ui/components/MarkdownBody.tsx").read_text(encoding="utf-8")
STYLES = (ROOT / "src/ui/styles.css").read_text(encoding="utf-8")
UPLOAD_PREVIEW = (ROOT / "src/ui/components/ArtifactAttachmentPreview.tsx").read_text(encoding="utf-8")
CHAT_COMPOSER = (ROOT / "src/ui/components/chat/ChatComposer.tsx").read_text(encoding="utf-8")
LAUNCH = (ROOT / "src/ui/components/chat/ConversationLaunchComposer.tsx").read_text(encoding="utf-8")
TASK_CHAIN = (ROOT / "src/ui/components/taskchain/TaskChainOverview.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# Mobile browsers auto-zoom focused controls below 16px. Composer/task text
# controls should be text-base on mobile and may fall back to text-sm on desktop;
# the global mobile guard catches any remaining form controls.
for marker in [
    'data-debug-id="conversation-composer-input"',
    'text-base text-white outline-none placeholder:text-zinc-600 focus:border-sky-400/60 sm:px-4 sm:text-sm',
    'data-debug-id="conversation-thread-title-input"',
    'text-base font-semibold text-white outline-none focus:border-sky-400/60 sm:text-sm',
]:
    require(marker in THREAD, f"ConversationThreadPage missing mobile 16px input marker: {marker}")
require("textareaClassName = 'w-full resize-none bg-transparent px-4 py-3 text-base" in CHAT_COMPOSER and "sm:text-sm" in CHAT_COMPOSER,
        "shared ChatComposer textarea should use 16px mobile text with desktop fallback")
require('data-debug-id="new-convo-input"' in LAUNCH and 'px-4 py-3 text-base leading-6 text-white sm:text-sm' in LAUNCH,
        "launch composer textarea should use 16px mobile text with desktop fallback")
require('data-debug-id={`taskchain-task-comment-input-${taskId}`}' in TASK_CHAIN and 'text-base text-white' in TASK_CHAIN and 'sm:text-sm' in TASK_CHAIN,
        "task comment input should use 16px mobile text with desktop fallback")
# NOTE: the agent-detail ChatComposer 16px override previously asserted against
# src/ui/components/App.tsx was dropped when that legacy component was removed
# (dead code; the app mounts AppShell). Live composer coverage remains above.
for marker in [
    "@media (max-width: 767px)",
    "input:not([type='checkbox']):not([type='radio']),",
    'font-size: 16px !important;',
]:
    require(marker in STYLES, f"global mobile form-control 16px guard missing: {marker}")

# Chat containers should not expose horizontal scrolling on mobile; min-w-0 and
# max-w-full keep flex children from forcing the viewport wider.
for marker in [
    'conversation-thread-page" className="flex h-full min-h-0 w-full max-w-full flex-col overflow-x-hidden',
    'conversation-thread-transcript" className="min-h-0 min-w-0 max-w-full flex-1 overflow-x-hidden',
    'wrapperClassName="relative h-full min-h-0 min-w-0 max-w-full overflow-hidden overflow-x-hidden"',
    'scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden',
]:
    require(marker in THREAD, f"conversation thread missing horizontal overflow guard: {marker}")
for marker in [
    "wrapperClassName = 'relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden'",
    "scrollClassName = 'chat-scrollbar h-full min-h-0 max-w-full space-y-[22px] overflow-y-auto overflow-x-hidden",
    'className={`msg group flex min-w-0 max-w-full',
    'flex min-w-0 max-w-full',
]:
    require(marker in LIST, f"ChatMessageList missing overflow guard: {marker}")

# Message bubbles, Markdown bodies, links, code, and attachment chips must wrap
# instead of widening the viewport.
for marker in [
    'min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere]',
    'className={`markdown min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere]',
]:
    require(marker in (LIST + MARKDOWN), f"missing bubble/markdown wrap marker: {marker}")
for marker in [
    '.markdown {',
    'overflow-wrap: anywhere;',
    'word-break: break-word;',
    '.markdown a,',
    '.markdown code',
    '.markdown pre,',
    '.markdown table,',
]:
    require(marker in STYLES, f"styles missing markdown overflow hardening: {marker}")
for marker in [
    'group block min-w-0 max-w-[min(320px,100%)] overflow-hidden',
    'flex min-w-0 max-w-full items-center gap-1',
]:
    require(marker in UPLOAD_PREVIEW, f"artifact preview chip missing width guard: {marker}")

# Pane captures are long terminal buffers; they should mount at the bottom by default.
for marker in [
    'function PaneCaptureOutput({ body, messageId }',
    'const preRef = useRef<HTMLPreElement | null>(null);',
    'node.scrollTop = node.scrollHeight;',
    'window.requestAnimationFrame(scrollToBottom)',
    'data-debug-id={`conversation-pane-capture-pre-${messageId}`}',
    '<PaneCaptureOutput body={message.body} messageId={message.messageId} />',
]:
    require(marker in THREAD, f"pane capture default-bottom behavior missing: {marker}")

# Accessibility best practice: preserve user zoom; do not add maximum-scale or
# user-scalable=no viewport hacks.
all_text = THREAD + LIST + MARKDOWN + STYLES + CHAT_COMPOSER + LAUNCH + TASK_CHAIN
require('maximum-scale' not in all_text, "must not disable mobile pinch zoom via maximum-scale")
require('user-scalable=no' not in all_text, "must not disable user scaling")

print("PASS: mobile chat no focus-zoom/no-horizontal-overflow static checks")
