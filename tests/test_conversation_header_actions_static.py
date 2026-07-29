#!/usr/bin/env python3
"""Static checks for compact conversation header actions."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THREAD_PATH = ROOT / "src/ui/components/chat/ConversationThreadPage.tsx"
THREAD = THREAD_PATH.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# Header state/refs and dismissal mirror the runtime/composer overflow pattern.
for marker in [
    "const [headerActionsOpen, setHeaderActionsOpen] = useState(false);",
    "const headerActionsRef = useRef<HTMLDivElement | null>(null);",
    "const headerActionsButtonRef = useRef<HTMLButtonElement | null>(null);",
    "if (!headerActionsOpen) return;",
    "isInsideHeaderActions",
    "setHeaderActionsOpen(false)",
    "event.key === 'Escape'",
]:
    require(marker in THREAD, f"missing header overflow state/dismissal marker: {marker}")

# Visible header controls should be compact icon buttons with accessible labels.
for marker in [
    'data-debug-id="conversation-thread-header" className="flex shrink-0 items-center',
    'data-debug-id="conversation-thread-status-chip"',
    'const runtimeButtonIcon =',
    'aria-label={`${runtimeButtonLabel} runtime`}',
    'title={`${runtimeButtonLabel} runtime`}',
    '>{runtimeButtonIcon}</button>',
    'data-debug-id="conversation-runtime-menu-btn"',
    'aria-label="Runtime controls"',
    'title="Runtime controls"',
    '>⚙</button>',
    'data-debug-id="taskchain-overview-toggle-btn"',
    "aria-label={taskChainOpen ? 'Hide task chain' : 'Show task chain'}",
    '>▤</button>',
    'data-debug-id="conversation-thread-overflow-menu-btn"',
    'aria-label="More conversation actions"',
    'aria-haspopup="menu"',
    'aria-expanded={headerActionsOpen ? \'true\' : \'false\'}',
]:
    require(marker in THREAD, f"missing compact accessible header marker: {marker}")

# Secondary actions and verbose details should live in the overflow menu instead of
# duplicating a long status/id row under the title.
for marker in [
    'data-debug-id="conversation-thread-overflow-menu" role="menu"',
    'role="menuitem" data-debug-id="conversation-thread-title-edit-btn"',
    'role="menuitem" data-debug-id="conversation-thread-refresh-btn"',
    'data-debug-id="conversation-thread-overflow-details"',
    'data-debug-id="conversation-thread-agent" className="truncate">Agent:',
    'data-debug-id="conversation-thread-instance" className="truncate">Instance:',
    'data-debug-id="conversation-thread-provider">Provider:',
    'data-debug-id="conversation-thread-tier">Tier:',
    'data-debug-id="conversation-thread-status">Status:',
]:
    require(marker in THREAD, f"missing overflow action/details marker: {marker}")
for old_visible in [
    "agent: {agentId || '—'}",
    "instance: {agentInstanceId || '—'}",
    "provider: {instanceProvider || '—'}",
    "tier: {instanceTier || '—'}",
    'className="mt-0.5 hidden flex-wrap gap-2 text-[11px] text-zinc-500 sm:flex"',
    '>Runtime</button>',
    '>Refresh</button>',
    "{taskChainOpen ? 'Hide Task Chain' : 'Task Chain'}",
]:
    require(old_visible not in THREAD, f"old duplicate/text header UI should be removed: {old_visible}")

# Compact summary keeps only non-duplicative runtime context visible.
for marker in [
    'data-debug-id="conversation-thread-compact-summary"',
    'data-debug-id="conversation-thread-bridge-summary"',
    'data-debug-id="conversation-thread-runtime-summary"',
    'const bridgeLabel =',
    'const runtimeConfigLabel =',
]:
    require(marker in THREAD, f"missing compact header summary marker: {marker}")

print("PASS: conversation header compact actions static checks")
