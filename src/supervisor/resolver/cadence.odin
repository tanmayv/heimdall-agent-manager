package resolver

// Check cadence, docs/specs/bridge-supervisor-engine.md §13.3: first check
// 10-30 min after supervisor start, then every 6 h ± 30 min; errors back off
// 15 min doubling to 6 h; a rate limit waits for GitHub's reset. Jitter is an
// explicit u in [0, 1) so callers use their own random source and tests are
// deterministic.

MINUTE :: 60
HOUR :: 60 * MINUTE
FIRST_CHECK_MIN :: 10 * MINUTE
FIRST_CHECK_SPAN :: 20 * MINUTE
CHECK_INTERVAL :: 6 * HOUR
CHECK_JITTER :: 30 * MINUTE
BACKOFF_MIN :: 15 * MINUTE
BACKOFF_MAX :: 6 * HOUR
// Spread bridges behind one NAT so they do not all retry the second the limit resets.
RATE_LIMIT_SPREAD :: 2 * MINUTE

@(private)
jitter :: proc(u: f64, span: i64) -> i64 {
	v := clamp(u, 0, 1)
	j := i64(v * f64(span))
	return min(j, span)
}

// schedule_start sets the first check after a supervisor start; a pending
// rate-limit reset still applies.
schedule_start :: proc(cache: ^Cache, start: i64, u: f64) {
	cache.next_check_at = max(start + FIRST_CHECK_MIN + jitter(u, FIRST_CHECK_SPAN), cache.rate_limit_reset_at)
}

// schedule_after sets next_check_at from a timer resolution's result.
schedule_after :: proc(cache: ^Cache, res: Result, now: i64, u: f64) {
	switch {
	case res.rate_limited:
		cache.rate_limit_reset_at = max(cache.rate_limit_reset_at, res.retry_at)
		cache.next_check_at = max(res.retry_at, now + MINUTE) + jitter(u, RATE_LIMIT_SPREAD)
		// A rate limit is not an error of ours: keep the backoff as it was.
	case res.status == .Incomplete:
		cache.backoff_s = BACKOFF_MIN if cache.backoff_s < BACKOFF_MIN else min(cache.backoff_s * 2, BACKOFF_MAX)
		cache.next_check_at = now + cache.backoff_s
	case:
		cache.backoff_s = 0
		cache.next_check_at = now + CHECK_INTERVAL - CHECK_JITTER + jitter(u, 2 * CHECK_JITTER)
	}
	cache.next_check_at = max(cache.next_check_at, cache.rate_limit_reset_at)
}

// check_due reports whether the timer should resolve now.
check_due :: proc(cache: Cache, now: i64) -> bool {
	return now >= cache.next_check_at && now >= cache.rate_limit_reset_at
}
