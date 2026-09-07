#!/usr/bin/env python3
"""Static regression checks for the AgentActivityBubbles component (Bubbles P3 +
animation polish).

Locks the user-authoritative behaviour that has no JS unit-test runner to guard it:
reserved fixed-height gutter (no composer shift), single clipped line, 3-dot ->
pill morph for the first bubble, slide-in/expand for subsequent bubbles, 4s
per-bubble lifetime, 400ms staggered <5min replay on OPEN (mount) only, subtle
keyframes + a prefers-reduced-motion fade fallback (dots skipped), and placement
above the composer.
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
    require("const DOTS_MS = 200;" in comp, "first-bubble dots show ~200ms before morphing")

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

    # --- Staggered replay + live append + component-owned expiry + de-dupe ---
    require(re.search(r"setTimeout\(\(\) => pushVisible\(item\), index \* REPLAY_STAGGER_MS\)", comp) is not None,
            "replayed bubbles are pushed on a 400ms * index stagger")
    require("phase: 'exiting'" in comp, "bubble transitions to an exiting phase before removal")
    require("prev.filter((b) => b.id !== id)" in comp, "bubble is removed after its lifetime")
    require("seenIdsRef" in comp, "live append de-dupes against already-surfaced ids")
    require("clearAllTimers" in comp and "window.clearTimeout" in comp, "timers cleared on unmount/switch")

    # --- Reserved fixed-height gutter (no composer shift) + single clipped line ---
    require("h-6" in comp, "gutter must have a fixed height so the composer never shifts")
    require("overflow-hidden" in comp, "row must clip overflowing bubbles")
    require("whitespace-nowrap" in comp, "bubbles stay on a single line (no wrap)")
    # The gutter is ALWAYS rendered (even empty) — no early `return null`.
    require("return null" not in comp, "gutter must always render (reserve space even when empty)")

    # --- First-bubble 3-dot -> pill morph; subsequent slide-in/expand ---
    require("liveCountRef.current === 0" in comp, "first-bubble detection = empty row")
    require("phase: 'pill', morphed: true" in comp, "first bubble morphs from dots into the pill")
    require("agent-bubble-dots-in" in comp, "dots phase uses the dots-in animation")
    require("agent-bubble-morph" in comp, "morph phase uses the morph animation")
    require("agent-bubble-pill-in" in comp, "subsequent bubbles slide in via pill-in")
    require("agent-bubble-exit" in comp, "exit uses the collapse-out animation")
    require("conversation-activity-bubble-dots" in comp, "the 3-dot indicator is rendered for the dots phase")

    # --- Muted styling, non-interactive, data-debug-ids ---
    require('data-debug-id="conversation-activity-bubbles"' in comp, "row has a data-debug-id")
    require("conversation-activity-bubble-${bubble.action" in comp, "each bubble has a data-debug-id")
    require("pointer-events-none" in comp, "row must not intercept composer clicks")
    require('aria-hidden="true"' in comp, "row is decorative/aria-hidden")
    require("text-zinc-400" in comp and "text-[11px]" in comp, "muted, low-contrast styling")

    # --- reduced-motion: skip the dots + fade only ---
    require("prefersReducedMotion()" in comp, "component checks the reduced-motion preference")
    require("liveCountRef.current === 0 && !prefersReducedMotion()" in comp,
            "under reduced motion the 3-dot morph is skipped (plain fade-in pill)")

    # --- CSS keyframes + reduced-motion fallback ---
    for kf in ("agent-bubble-pill-in", "agent-bubble-morph", "agent-bubble-dots-in", "agent-bubble-collapse-out"):
        require(f"@keyframes {kf}" in css, f"{kf} keyframes defined")
    require(".agent-bubble-pill-in" in css and ".agent-bubble-morph" in css
            and ".agent-bubble-dots-in" in css and ".agent-bubble-exit" in css,
            "animation utility classes defined")
    # Expand/collapse drives the sibling "make room" — assert max-width is animated.
    require("max-width: 0" in css and "max-width: 240px" in css,
            "bubbles expand/collapse via max-width to push siblings over")
    require("@media (prefers-reduced-motion: reduce)" in css, "reduced-motion media block present")
    rm = css.split("@media (prefers-reduced-motion: reduce)", 1)[1]
    # Inside reduced-motion, the redefined keyframes must be opacity-only (no motion).
    rm_head = rm[: rm.find(".agent-bubble-dot { animation: none")] if ".agent-bubble-dot { animation: none" in rm else rm
    require("transform" not in rm_head, "reduced-motion keyframes fade only (no slide/scale/translate)")
    require("max-width" not in rm_head, "reduced-motion keyframes must not animate layout (no expand)")

    # --- Mounted above the composer in the thread page ---
    require("import AgentActivityBubbles from './AgentActivityBubbles';" in thread,
            "thread imports the component")
    require("<AgentActivityBubbles instanceId={agentInstanceId} />" in thread,
            "component is rendered for the currently-viewed instance")
    shell_idx = thread.find('data-debug-id="conversation-composer-shell"')
    bubbles_idx = thread.find("<AgentActivityBubbles instanceId={agentInstanceId} />")
    strip_idx = thread.find("<CurrentTaskStrip")
    require(shell_idx != -1 and bubbles_idx != -1 and strip_idx != -1, "composer landmarks present")
    require(shell_idx < bubbles_idx < strip_idx,
            "bubbles must render inside the composer shell, above the composer body")

    print("UI AGENT ACTIVITY BUBBLES (BUBBLES P3 + POLISH) TEST PASSED")


if __name__ == "__main__":
    main()
