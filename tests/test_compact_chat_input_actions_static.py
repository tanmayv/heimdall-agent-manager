#!/usr/bin/env python3
"""Static checks for compact chat composer action buttons.

Locks in mobile three-dot action menu for Upload / Pane Capture, icon-only
visible controls, and a flexing textarea that gets the available width.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THREAD = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# State/refs and dismissal wiring for the mobile action overflow.
for marker in [
    "composerActionsOpen",
    "composerActionsRef",
    "composerActionsButtonRef",
    "fileInputRef",
    "isInsideComposerActions",
    "document.addEventListener('mousedown', onPointerDown)",
    "document.addEventListener('touchstart', onPointerDown",
    "document.addEventListener('focusin', onFocusIn)",
    "document.addEventListener('keydown', onKeyDown)",
    "event.key === 'Escape'",
]:
    require(marker in THREAD, f"missing composer overflow dismissal marker: {marker}")

# Mobile overflow menu contains Upload and Pane Capture actions.
for marker in [
    'data-debug-id="conversation-composer-actions-menu-btn"',
    'aria-label="More composer actions"',
    'aria-haspopup="menu"',
    'data-debug-id="conversation-composer-actions-menu"',
    'role="menu"',
    'data-debug-id="conversation-composer-actions-upload"',
    '>Upload<',
    'data-debug-id="conversation-composer-actions-pane"',
    '>Pane capture<',
    'sm:hidden',
]:
    require(marker in THREAD, f"missing mobile action menu marker: {marker}")

# Desktop uses compact icon buttons with accessible labels/titles rather than
# text-heavy Upload/Pane/Send buttons beside the input.
for marker in [
    'data-debug-id="conversation-attach-btn"',
    'aria-label="Upload attachment"',
    'title="Upload attachment"',
    'sm:grid',
    'data-debug-id="conversation-request-pane-btn"',
    'aria-label="Request terminal pane capture"',
    '>▣</button>',
    'data-debug-id="conversation-composer-send-btn"',
    'aria-label="Send message"',
    "{hasUploadingAttachments ? '⇧' : '↑'}",
]:
    require(marker in THREAD, f"missing compact desktop action marker: {marker}")

# Textarea should have room to shrink/grow between compact actions.
for marker in [
    'className="min-h-[44px] min-w-0 flex-1 resize-none',
    'gap-1.5 sm:gap-2',
    'w-[44px] shrink-0',
]:
    require(marker in THREAD, f"missing wider-input layout marker: {marker}")

# The old text-heavy visible pane/send labels should not remain in the composer.
require('>Pane</button>' not in THREAD, "text Pane button should be replaced by an icon/action menu")
require("{hasUploadingAttachments ? 'Uploading…' : 'Send'}" not in THREAD,
        "text Send button should be replaced by compact icon state")

print("PASS: compact chat input actions static checks")
