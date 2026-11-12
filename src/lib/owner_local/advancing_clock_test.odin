package owner_local

import "core:sync"

// C3: every test in this package runs under a clock hook that advances on
// every read (+1 ms per call). A proc that re-reads the clock where it should
// reuse its operation's derived time sees a different value and a
// recomputed deadline or digest stops matching. The hook starts at 1 ms, so
// a missing or stale hint still clamps to the store's high-water clock and
// tests keep their simulated times.
advancing_clock_reads: i64
advancing_clock :: proc() -> i64 {return sync.atomic_add(&advancing_clock_reads,1)+1}

@(init)
advancing_clock_install :: proc "contextless" () {default_clock=advancing_clock}
