package app

// REQ-SHELL-9 reaper tests — the WINDOW, and the fact that it rides the existing sweep.
//
// The row work is asserted in src/hub/service/shell_session/shell_session_req9_test.odin,
// which drives shell_session_reap_aged_servers with injected timestamps. What is left for
// this package is the part that lives here: the constant itself, and its relationship to
// the reaper's other thresholds.
//
// WHAT THIS FILE HONESTLY CANNOT ASSERT, stated rather than papered over.
// reaper_sweep_aged_servers takes an ^App_Graph and does three things: read the clock,
// parse it, call the service. Reaching it from a test means standing up every repository
// in the hub, so what would be under test is the harness. That seam is the same one where
// REQ-SHELL-14 shipped a `defer delete(now_str)` on a temp-arena string (fixed in
// 1ba0d4ba) — so it is a KNOWN uncovered three lines, not an assumed-safe one. The
// mitigation is that the proc is three lines long and that the clock_now borrow is
// documented at the call site with the reason.
//
// "NO NEW PERIODIC TIMER" (AC6) IS LIKEWISE NOT A UNIT TEST. It is a structural claim
// about the whole package, and the check that actually answers it is a grep for sleep
// loops and thread spawns across src/hub — reported with the handoff. What IS asserted
// here is the precondition that makes the claim meaningful: the age window is a named
// constant of this package, sitting with the other reaper thresholds, rather than a
// literal buried in a sweep.

import "core:testing"

// The window is one day, as the requirement states in so many words: "kill all servers
// once task chain completes or are older than 1 day". Asserted against the arithmetic
// rather than against a repeated literal, so a typo in either is visible.
@(test)
t9_server_max_age_is_exactly_one_day :: proc(t: ^testing.T) {
	testing.expect_value(t, REAPER_SERVER_MAX_AGE_MS, 86_400_000)
	testing.expect_value(t, REAPER_SERVER_MAX_AGE_MS, 24 * 60 * 60 * 1000)
}

// THE THRESHOLDS MUST NOT BE UNIFIED, and this test exists to say so to whoever notices
// three age constants in one file and reaches for a refactor. They answer three different
// questions and the numbers are not interchangeable:
//   REAPER_STALE_MS         90s   — "is this agent instance responding right now"
//   REAPER_BRIDGE_GONE_MS    1h   — "is this bridge never coming back"
//   REAPER_SERVER_MAX_AGE_MS 24h  — "has this server been allowed to live long enough"
// The last is not even a heuristic: it is a product decision about a permitted lifetime,
// so collapsing it into a liveness number would not make it less precise, it would make
// it a different promise. The ordering asserted below is the cheap, durable way to notice
// such a collapse.
@(test)
t9_reaper_thresholds_stay_distinct_and_ordered :: proc(t: ^testing.T) {
	testing.expect(t, REAPER_STALE_MS < REAPER_BRIDGE_GONE_MS, "liveness must be far tighter than absence")
	testing.expect(t, REAPER_BRIDGE_GONE_MS < REAPER_SERVER_MAX_AGE_MS, "a permitted lifetime must outlast an absence verdict")
}

// The sweep interval must stay far below the age window, or "older than a day" would be
// enforced with a granularity comparable to the window itself. At a 20-second interval
// the age reap fires 4320 times per window — which is also why the reap's idempotence is
// load-bearing rather than a nicety, and why it must NOT re-dispatch an intent it has
// already recorded.
@(test)
t9_sweep_interval_is_far_finer_than_the_age_window :: proc(t: ^testing.T) {
	interval_ms := DEFAULT_REAPER_INTERVAL_SECONDS * 1000
	testing.expect(t, i64(interval_ms) * 100 < REAPER_SERVER_MAX_AGE_MS, "the sweep must be orders of magnitude finer than the window")
}
