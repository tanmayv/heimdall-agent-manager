#!/usr/bin/env python3
"""Static contract: a conversation's chain coordinator display name is surfaced
by the hub and rendered as a yellow (amber) accent in the sidebar rail AND the
command palette, without tinting the conversation title or the rest of the row.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTENT_HANDLERS = (ROOT / "src" / "hub" / "transport" / "http" / "content_handlers.odin").read_text(encoding="utf-8")
WIRING = (ROOT / "src" / "hub" / "app" / "wiring.odin").read_text(encoding="utf-8")
SIDEBAR_API = (ROOT / "src" / "ui" / "api" / "endpoints" / "sidebar.ts").read_text(encoding="utf-8")
APP_SHELL = (ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx").read_text(encoding="utf-8")
PALETTE = (ROOT / "src" / "ui" / "components" / "command-palette" / "CommandPalette.tsx").read_text(encoding="utf-8")

# Design-system yellow token used for the coordinator accent.
YELLOW_CLASS = "text-amber-300"


def require(text: str, snippet: str, label: str) -> None:
    if snippet not in text:
        raise AssertionError(f"missing {label}: {snippet}")


def main() -> None:
    # --- Hub resolves + emits the coordinator per conversation ------------------
    for snippet in [
        # Resolver: chain -> coordinator instance -> display name, with the
        # documented edge cases (no chain / no coordinator / self-coordinator).
        "chat_coordinator :: proc",
        "taskchain_service.get_chain",
        "chain.coordinator_agent_instance_id",
        'if coordinator=="" || coordinator==c.agent_instance_id do return "",""',
        "agent_service.get_instance(h.agents,auth,coordinator)",
        # Wire fields emitted by the sidebar/inbox serializer.
        '\\"coordinator_agent_instance_id\\":',
        '\\"coordinator_display_name\\":',
    ]:
        require(CONTENT_HANDLERS, snippet, "hub coordinator resolution/emit")

    require(CONTENT_HANDLERS, "taskchains: ^taskchain_service.Taskchain_Service", "content handler taskchain dep")
    require(WIRING, "taskchains = &graph.taskchains, event_bus = &graph.event_bus}", "content handler wiring")

    # --- UI API normalizes the coordinator fields ------------------------------
    for snippet in [
        "coordinatorAgentInstanceId?: string;",
        "coordinatorDisplayName?: string;",
        "raw?.coordinator_display_name",
    ]:
        require(SIDEBAR_API, snippet, "sidebar api coordinator fields")

    # --- Sidebar rail renders the yellow coordinator name ----------------------
    require(APP_SHELL, "coordinatorDisplayName?: string;", "shell summary coordinator field")
    require(APP_SHELL, "coordinatorDisplayName: c.coordinatorDisplayName", "shell coordinator mapping")
    require(APP_SHELL, "sidebar-session-coordinator-${conversation.conversationId}", "sidebar coordinator debug id")
    if f"conversation.coordinatorDisplayName ?" not in APP_SHELL:
        raise AssertionError("sidebar must guard the coordinator accent (omit when empty)")
    # The accent span must use the yellow token.
    _require_yellow_span(APP_SHELL, "sidebar-session-coordinator", "sidebar")

    # Title/agent-name spans must remain un-tinted (no amber on the primary label).
    if "flex-1 truncate\" >" in APP_SHELL:
        raise AssertionError("unexpected malformed label span")

    # --- Command palette renders the yellow coordinator name -------------------
    require(PALETTE, "coordinatorDisplayName?: string;", "palette coordinator field")
    require(PALETTE, "isConvo && result.convo.coordinatorDisplayName", "palette coordinator guard")
    require(PALETTE, "command-palette-result-coordinator-${idx}", "palette coordinator debug id")
    _require_yellow_span(PALETTE, "command-palette-result-coordinator", "palette")

    print("PASS: coordinator display name is resolved by the hub and rendered as a yellow accent in the sidebar + command palette")


def _require_yellow_span(text: str, debug_id_prefix: str, where: str) -> None:
    """Assert the span carrying `debug_id_prefix` also carries the yellow token."""
    idx = text.find(debug_id_prefix)
    if idx < 0:
        raise AssertionError(f"{where}: coordinator span not found ({debug_id_prefix})")
    # Look at the enclosing span opening tag (a small window around the debug id).
    window = text[max(0, idx - 200): idx + 200]
    if YELLOW_CLASS not in window:
        raise AssertionError(f"{where}: coordinator accent must use the {YELLOW_CLASS} yellow token")


if __name__ == "__main__":
    main()
