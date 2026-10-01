package shell_session

// REQ-SHELL-8 item 6, service layer: the row-retention window and the arithmetic
// that turns it into a cutoff.
//
// The repository tests (repository/sqlite/shell_session_retention_test.odin) cover
// which rows the DELETE selects. What is checked here is the part no delete count can
// reveal: that the window is the right LENGTH and sits correctly against the bridge's
// output window. An off-by-a-day here silently reshapes retention while every other
// test still passes.

import "core:testing"
import "core:time"
import "odin_test:hub/platform"

// THE INEQUALITY THAT MUST HOLD ACROSS THE WHOLE FEATURE. Output is reclaimed at 5
// days (BRIDGE_SHELL_OUTPUT_RETENTION, src/bridge/shell_output_retention.odin); rows
// must live LONGER. If they did not, a user would be shown a list of sessions whose
// logs had already been reclaimed and would get an error opening any of them — a row
// outliving the only thing it is useful for.
//
// The 5-day figure is restated here rather than imported because the constant lives in
// the bridge binary, a separate package: this test is the seam where the two halves of
// the chain are checked against each other, and restating it is what makes a change to
// either side fail here instead of silently breaking the property.
@(test)
test_row_retention_outlives_output_retention :: proc(t: ^testing.T) {
	bridge_output_retention := 5 * 24 * time.Hour
	testing.expect(t, HUB_SHELL_SESSION_ROW_RETENTION > bridge_output_retention,
		"a row must never be visible with its output already reclaimed: rows (7d) > output (5d)")
	testing.expect(t, HUB_SHELL_SESSION_ROW_RETENTION == 7 * 24 * time.Hour,
		"the row window is 7 days — change it together with the other two, not alone")
}

// The cutoff arithmetic, checked against a hand-computed date. A test that only
// asserted "the cutoff is earlier than now" would pass for a window of one second.
@(test)
test_row_retention_cutoff_is_seven_days_back :: proc(t: ^testing.T) {
	cutoff := shell_session_row_retention_cutoff("2026-09-28T12:00:00Z")
	testing.expectf(t, cutoff == "2026-09-21T12:00:00Z",
		"seven days before 2026-09-28T12:00:00Z is 2026-09-21T12:00:00Z, got %q", cutoff)

	// Across a month boundary, where naive day arithmetic goes wrong.
	cutoff2 := shell_session_row_retention_cutoff("2026-03-03T06:30:00Z")
	testing.expectf(t, cutoff2 == "2026-02-24T06:30:00Z",
		"seven days before 2026-03-03T06:30:00Z is 2026-02-24T06:30:00Z, got %q", cutoff2)
}

// A malformed instant must yield NO cutoff rather than a plausible-looking one. This
// is the dangerous direction: a parser that quietly returned the zero Time would
// produce a cutoff in 1970 — which selects nothing — or, worse, one far in the future,
// which would select the entire table. Refusing is the only safe failure.
@(test)
test_row_retention_cutoff_refuses_a_malformed_instant :: proc(t: ^testing.T) {
	testing.expect(t, shell_session_row_retention_cutoff("") == "", "an empty instant yields no cutoff")
	testing.expect(t, shell_session_row_retention_cutoff("not-a-timestamp") == "", "garbage yields no cutoff")
	testing.expect(t, shell_session_row_retention_cutoff("2026-09-28") == "", "a date with no time yields no cutoff")
}

// The parser added to platform for this feature is the exact inverse of the formatter
// already there. Checked as a round trip because the two are only useful as a pair —
// the cutoff is parsed from a formatted column and written back for comparison
// against other formatted columns, so a mismatch in either direction breaks the
// compare silently.
@(test)
test_platform_rfc3339_round_trips :: proc(t: ^testing.T) {
	original := "2026-09-28T16:20:05Z"
	parsed, ok := platform.parse_rfc3339_utc(original)
	testing.expect(t, ok, "a formatted instant parses back")
	testing.expectf(t, platform.format_rfc3339_utc(parsed) == original,
		"round trip is lossless, got %q", platform.format_rfc3339_utc(parsed))

	_, bad_ok := platform.parse_rfc3339_utc("nonsense")
	testing.expect(t, !bad_ok, "a malformed instant reports failure rather than the epoch")
}
