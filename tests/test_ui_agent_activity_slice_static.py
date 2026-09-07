#!/usr/bin/env python3
"""Static regression checks for the transient agent-activity slice + its ephemeral
`agent_action` WS routing (Bubbles P2).

The repo has no JS unit-test runner, so these lock the load-bearing reducer logic
(ring cap = 4, lastActionAt = max, <5min replay-window filter) and the two hard
invariants:
  * `agent_action` is routed ONLY to the transient slice, never to an RTK Query
    cache (no invalidateTags / updateQueryData / endpoint initiate in its handler);
  * the slice is registered in the store so it actually receives dispatches.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SLICE = ROOT / "src" / "ui" / "store" / "agentActivitySlice.ts"
STORE = ROOT / "src" / "ui" / "store" / "store.ts"
WS = ROOT / "src" / "ui" / "api" / "wsInvalidation.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def main() -> None:
    slice_src = SLICE.read_text(encoding="utf-8")
    store_src = STORE.read_text(encoding="utf-8")
    ws = WS.read_text(encoding="utf-8")

    # --- Slice constants: ring cap 4, replay window 5 minutes ---
    require("export const AGENT_ACTIVITY_RING_CAP = 4;" in slice_src,
            "ring buffer cap must be 4")
    require("export const AGENT_ACTIVITY_REPLAY_WINDOW_MS = 5 * 60_000;" in slice_src,
            "replay window must be 5 minutes")

    # --- Reducer: append + ring-trim to the cap + lastActionAt = max ---
    require("agentActionReceived(state" in slice_src, "slice must expose agentActionReceived reducer")
    require("if (!instanceId || !summary) return;" in slice_src,
            "reducer must ignore malformed events (missing instance/summary)")
    require("buffer.push(item);" in slice_src, "reducer appends the new action to the buffer")
    require("buffer.splice(0, buffer.length - AGENT_ACTIVITY_RING_CAP);" in slice_src,
            "reducer must trim the OLDEST entries down to the ring cap")
    require(
        "state.lastActionAt[instanceId] = Math.max(Number(state.lastActionAt[instanceId] || 0), ts);"
        in slice_src,
        "lastActionAt must be the max of the existing value and the new ts",
    )
    # id embeds instanceId + ts + seq so replayed + live bubbles never collide.
    require("`${instanceId}:${ts}:${state.seq}`" in slice_src,
            "action id must be `${instanceId}:${ts}:${seq}` for stable, unique keys")

    # --- Pure replay-window selector: filter to <5min, oldest-first ---
    require("export function selectReplayableActions(" in slice_src,
            "must export the pure selectReplayableActions helper")
    require("now - Number(item?.ts || 0) < AGENT_ACTIVITY_REPLAY_WINDOW_MS" in slice_src,
            "replay must drop actions older than the 5-minute window")
    require(re.search(r"\.sort\(\(left, right\) => Number\(left\?\.ts \|\| 0\) - Number\(right\?\.ts \|\| 0\)\)", slice_src) is not None,
            "replayable actions must be sorted oldest-first for staggered replay")

    require("export const selectAgentActivityBuffer" in slice_src, "must export a buffer selector")
    require("export const selectAgentLastActionAt" in slice_src, "must export a lastActionAt selector")

    # --- Store registration (so dispatches actually land) ---
    require("import agentActivityReducer from './agentActivitySlice';" in store_src,
            "store must import the agentActivity reducer")
    require("agentActivity: agentActivityReducer," in store_src,
            "store combineReducers must register agentActivity")

    # --- WS routing: agent_action -> slice ONLY, no cache churn ---
    require("import { agentActionReceived } from '../store/agentActivitySlice';" in ws,
            "wsInvalidation must import agentActionReceived")
    require("case 'agent_action':" in ws, "handleUserWsEvent must handle the agent_action event")
    require("handleAgentActionEvent(dispatch, payload);" in ws,
            "agent_action must be routed to its dedicated handler")

    # Isolate the handler body and assert it never touches an RTK Query cache.
    match = re.search(r"function handleAgentActionEvent\(dispatch: any, payload: any\) \{(.*?)\n\}", ws, re.S)
    require(match is not None, "handleAgentActionEvent must be defined")
    body = match.group(1)
    require("dispatch(agentActionReceived({" in body, "handler dispatches agentActionReceived to the slice")
    require("invalidateTags" not in body, "agent_action handler MUST NOT invalidate any RTK cache")
    require("updateQueryData" not in body, "agent_action handler MUST NOT patch any RTK cache")
    require("upsertQueryData" not in body, "agent_action handler MUST NOT upsert any RTK cache")
    require(".initiate(" not in body, "agent_action handler MUST NOT trigger any refetch")

    print("UI AGENT ACTIVITY SLICE (BUBBLES P2) TEST PASSED")


if __name__ == "__main__":
    main()
