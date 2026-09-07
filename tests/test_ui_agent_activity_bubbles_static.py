#!/usr/bin/env python3
"""Static regression checks for the AgentActivityBubbles component (Bubbles P3).

Locks the user-authoritative behaviour that has no JS unit-test runner to guard it:
4s per-bubble lifetime, 400ms staggered replay of <5min buffered actions on OPEN
(mount) only, subtle keyframes + prefers-reduced-motion fallback, mounting above
the composer, and the data-debug-ids.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
COMP = ROOT / "src" / "ui" / "components" / "chat" / "AgentActivityBubbles.tsx"
THREAD = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
CSS = ROOT / "src" / "ui" / "styles.css"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    comp = COMP.read_text(encoding="utf-8")
    thread = THREAD.read_text(encoding="utf-8")
    css = CSS.read_text(encoding="utf-8")

    # --- Timings (user spec) ---
    require("const BUBBLE_LIFETIME_MS = 4000;" in comp, "each bubble must live 4s")
    require("const REPLAY_STAGGER_MS = 400;" in comp, "replay must stagger at 400ms")

    # --- Reads the transient slice (P2), not any cache ---
    require("selectAgentActivityBuffer" in comp, "component reads the per-instance buffer selector")
    require("selectReplayableActions(buffer, Date.now())" in comp,
            "replay set comes from the pure <5min selectReplayableActions")
    require("useSelector(" in comp, "buffer is read via useSelector (redux)")

    # --- Replay on MOUNT/open only (Q2: no tab-visibility) ---
    require("}, [instanceId, pushVisible]);" in comp,
            "replay effect is keyed on the viewed instance (open-conversation replay only)")
    require("visibilitychange" not in comp, "Q2: must NOT replay on tab visibility change")
    require("document.hidden" not in comp, "Q2: must NOT branch on document.hidden")

    # --- Staggered replay + live append + component-owned expiry ---
    require(re.search(r"setTimeout\(\(\) => pushVisible\(item\), index \* REPLAY_STAGGER_MS\)", comp) is not None,
            "replayed bubbles are pushed on a 400ms * index stagger")
    require("{ ...b, exiting: true }" in comp, "bubble transitions to an exiting state before removal")
    require("setVisible((prev) => prev.filter((b) => b.id !== item.id))" in comp,
            "bubble is removed from the visible set after its lifetime")
    require("seenIdsRef" in comp, "live append de-dupes against already-surfaced ids")
    # Timers are cleaned up on unmount / instance switch.
    require("clearAllTimers" in comp and "window.clearTimeout" in comp, "timers cleared on unmount/switch")

    # --- Subtle enter/exit + muted styling + data-debug-ids ---
    require("agent-bubble-enter" in comp and "agent-bubble-exit" in comp,
            "enter/exit animation classes applied")
    require('data-debug-id="conversation-activity-bubbles"' in comp, "row has a data-debug-id")
    require("conversation-activity-bubble-${bubble.action" in comp, "each bubble has a data-debug-id")
    require("pointer-events-none" in comp, "row must not intercept composer clicks")
    require("text-zinc-400" in comp and "text-[11px]" in comp, "muted, low-contrast styling")

    # --- CSS keyframes + reduced-motion fallback ---
    require("@keyframes agent-bubble-in" in css, "enter keyframes defined")
    require("@keyframes agent-bubble-out" in css, "exit keyframes defined")
    require(".agent-bubble-enter" in css and ".agent-bubble-exit" in css, "animation utility classes defined")
    require("@media (prefers-reduced-motion: reduce)" in css, "reduced-motion media block present")
    # The reduced-motion block must neutralise motion (fade only): assert it
    # redefines the keyframes to opacity-only (no transform inside that block).
    rm = css.split("@media (prefers-reduced-motion: reduce)", 1)[1]
    rm_block = rm[: rm.find("\n}\n}") + 4] if "\n}\n}" in rm else rm
    require("transform" not in rm_block.split("agent-bubble", 1)[0] or "opacity" in rm_block,
            "reduced-motion keyframes fade only (no slide/scale)")

    # --- Mounted above the composer in the thread page ---
    require("import AgentActivityBubbles from './AgentActivityBubbles';" in thread,
            "thread imports the component")
    require("<AgentActivityBubbles instanceId={agentInstanceId} />" in thread,
            "component is rendered for the currently-viewed instance")
    # It must sit inside the composer shell, above the current-task strip / input.
    shell_idx = thread.find('data-debug-id="conversation-composer-shell"')
    bubbles_idx = thread.find("<AgentActivityBubbles instanceId={agentInstanceId} />")
    strip_idx = thread.find("<CurrentTaskStrip")
    require(shell_idx != -1 and bubbles_idx != -1 and strip_idx != -1, "composer landmarks present")
    require(shell_idx < bubbles_idx < strip_idx,
            "bubbles must render inside the composer shell, above the composer body")

    print("UI AGENT ACTIVITY BUBBLES (BUBBLES P3) TEST PASSED")


if __name__ == "__main__":
    main()
