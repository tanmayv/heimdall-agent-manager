#!/usr/bin/env python3
"""Static guard for H13: the sidebar status dot animates ONLY when working.

Full-stack: (R1) hub conversation summary emits activity_status; (R2) sidebar.ts
normalizes activity_status -> activityStatus; (R3) AppShell StatusDot animates
only when working (runtime live AND activity in {active,busy,working}) and exposes
data-working for tests.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HUB = ROOT / "src" / "hub" / "transport" / "http" / "content_handlers.odin"
SIDEBAR = ROOT / "src" / "ui" / "api" / "endpoints" / "sidebar.ts"
APPSHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
WORKING = ROOT / "src" / "ui" / "components" / "shell" / "agentWorking.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    hub = HUB.read_text(encoding="utf-8")
    sidebar = SIDEBAR.read_text(encoding="utf-8")
    appshell = APPSHELL.read_text(encoding="utf-8")
    working = WORKING.read_text(encoding="utf-8")

    # --- R1: hub conversation summary emits activity_status (additive) ---
    require("activity_status=inst.activity_status" in hub,
            "hub must capture activity_status from the instance (R1)")
    require('"\\",\\"activity_status\\":\\""' in hub or 'activity_status\\":\\"' in hub,
            "hub conversation summary JSON must emit activity_status (R1)")

    # --- R2: sidebar normalize maps activity_status -> activityStatus ---
    require("activity_status || raw?.activityStatus" in sidebar,
            "sidebar normalize must read raw.activity_status (R2)")
    require("activityStatus?: string;" in sidebar,
            "SidebarConversation type must include activityStatus (R2)")
    require("activityStatus,\n  };" in sidebar or "activityStatus," in sidebar,
            "normalized sidebar object must include activityStatus (R2)")

    # --- R3: the working predicate mirrors the canonical definition ---
    require("state !== 'live'" in working and
            "'active'" in working and "'busy'" in working and "'working'" in working,
            "isAgentWorking must require live runtime AND active/busy/working activity (R3)")

    # --- R3: StatusDot animates only when working + exposes data-working ---
    require("isAgentWorking(state, activityStatus)" in appshell,
            "StatusDot must compute working from activity + runtime (R3)")
    require("working ? ' animate-pulse' : ''" in appshell,
            "StatusDot must animate-pulse ONLY when working (R3)")
    require("data-working={working ? 'true' : 'false'}" in appshell,
            "StatusDot must expose data-working for tests (R3)")
    # The sidebar caller threads activityStatus through.
    require("activityStatus={conversation.activityStatus}" in appshell,
            "the sidebar dot caller must pass conversation.activityStatus (R3)")
    # Stopped stays a static hollow dot (unchanged).
    require("border border-zinc-500 bg-transparent" in appshell,
            "stopped must remain a static hollow dot (unchanged)")

    print("PASS: H13 status-dot working static guard")


if __name__ == "__main__":
    main()
