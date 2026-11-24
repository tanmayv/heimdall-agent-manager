package http

import "core:testing"

@(test)
test_experiment_next_updated_at_is_strictly_monotonic :: proc(t: ^testing.T) {
	// Later clock: used as is.
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:09Z", "2026-10-25T05:00:00Z"), "2026-10-25T05:00:09Z")
	// Same second or clock behind the stored row: one second after the stored row.
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:00Z", "2026-10-25T05:00:00Z"), "2026-10-25T05:00:01Z")
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T04:59:00Z", "2026-10-25T05:00:00Z"), "2026-10-25T05:00:01Z")
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T23:59:59Z", "2026-10-25T23:59:59Z"), "2026-10-26T00:00:00Z")
	// No previous row, or an unreadable one: the clock value.
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:00Z", ""), "2026-10-25T05:00:00Z")
	testing.expect_value(t, experiment_next_updated_at("2026-10-25T05:00:00Z", "garbage"), "2026-10-25T05:00:00Z")
}
