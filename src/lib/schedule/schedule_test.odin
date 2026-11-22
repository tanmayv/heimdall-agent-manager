package schedule

import "core:mem"
import "core:strings"
import "core:testing"
import "core:time/timezone"

NY_TZIF :: #load("testdata/America_New_York.tzif")

tracked :: proc(t: ^testing.T, scenario: proc(t: ^testing.T)) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    context.allocator = mem.tracking_allocator(&track)
    scenario(t)
    testing.expect_value(t, len(track.allocation_map), 0)
}

test_format :: proc(t: ^testing.T, ms: i64) -> string {
    out := format_rfc3339_utc(ms)
    defer delete(out)
    // Assertions below compare a temporary view; the owned result has been checked and freed.
    return strings.clone(out, context.temp_allocator)
}

@(test)
test_parse_interval :: proc(t: ^testing.T) {
    tracked(t, test_parse_interval_scenario)
}
test_parse_interval_scenario :: proc(t: ^testing.T) {
	testing.expect(t, parse_interval_seconds("60s") == 60, "60s should be 60")
	testing.expect(t, parse_interval_seconds("30s") == 30, "30s should be 30")
	testing.expect(t, parse_interval_seconds("5m") == 300, "5m should be 300")
	testing.expect(t, parse_interval_seconds("2h") == 7200, "2h should be 7200")
	testing.expect(t, parse_interval_seconds("1d") == 86400, "1d should be 86400")
	testing.expect(t, parse_interval_seconds("90") == 90, "bare 90 should be 90")
	testing.expect(t, parse_interval_seconds("") == 0, "empty should be 0")
	testing.expect(t, parse_interval_seconds("abc") == 0, "abc should be 0")
	testing.expect(t, parse_interval_seconds("-10s") == 0, "negative should be 0")
}

@(test)
test_parse_rfc3339 :: proc(t: ^testing.T) {
    tracked(t, test_parse_rfc3339_scenario)
}
test_parse_rfc3339_scenario :: proc(t: ^testing.T) {
	ms, ok := parse_rfc3339_ms("1970-01-01T00:00:00Z")
	testing.expect(t, ok, "parse unix epoch ok")
	testing.expect(t, ms == 0, "unix epoch should be 0 ms")

	ms2, ok2 := parse_rfc3339_ms("2026-01-01T00:00:00Z")
	testing.expect(t, ok2, "parse 2026 ok")
	testing.expect(t, ms2 == 1_767_225_600_000, "2026-01-01 should be 1_767_225_600_000 ms")

	_, ok3 := parse_rfc3339_ms("invalid")
	testing.expect(t, !ok3, "invalid format should fail")

	_, ok4 := parse_rfc3339_ms("2026-13-01T00:00:00Z")
	testing.expect(t, !ok4, "month 13 should fail")

	formatted := test_format(t, ms2)
	testing.expect(t, formatted == "2026-01-01T00:00:00Z", "format matches original timestamp")

	ms5, ok5 := parse_rfc3339_ms("2026-12-24T15:30:45Z")
	testing.expect(t, ok5 && ms5 == 1_798_126_245_000, "non-midnight timestamp parses to exact ms")
	testing.expect(t, test_format(t, ms5) == "2026-12-24T15:30:45Z", "non-midnight timestamp round-trips")

	ms6, ok6 := parse_rfc3339_ms("  1970-01-01T00:00:00Z ")
	testing.expect(t, ok6 && ms6 == 0, "surrounding whitespace is trimmed")
}

@(test)
test_cron_evaluator :: proc(t: ^testing.T) {
    tracked(t, test_cron_evaluator_scenario)
}
test_cron_evaluator_scenario :: proc(t: ^testing.T) {
	// 2026-12-24 is Thursday.
	days_dec24 := days_from_civil(2026, 12, 24)
	after_ms := (i64(days_dec24) * 86400 + 15 * 3600) * 1000 // 15:00 UTC (10:00 EST)

	ny, ny_ok := timezone.region_load_from_buffer(NY_TZIF, "America/New_York")
	testing.expect_value(t, ny_ok, true)
	if !ny_ok do return
	defer timezone.region_destroy(ny)

	// Case 1: Normal next run on Friday Dec 25 at 09:00 EST (14:00 UTC)
	next1, ok1 := next_cron_slot_region("0 9 * * 1-5", ny, "[]", 0, 0, after_ms)
	testing.expect(t, ok1, "cron eval ok")
	testing.expect(t, test_format(t, next1) == "2026-12-25T14:00:00Z", "next run is Friday 09:00 EST")

	// Case 2: Holiday blackout on Friday Dec 25 -> skips weekend, lands on Monday Dec 28 09:00 EST (14:00 UTC)
	next2, ok2 := next_cron_slot_region("0 9 * * 1-5", ny, "[\"2026-12-25\"]", 0, 0, after_ms)
	testing.expect(t, ok2, "cron eval with blackout ok")
	testing.expect(t, test_format(t, next2) == "2026-12-28T14:00:00Z", "next run skips Friday + weekend to Monday 09:00 EST")

	// Case 3: Blackout on both Friday Dec 25 AND Monday Dec 28 -> skips to Tuesday Dec 29 09:00 EST (14:00 UTC)
	next3, ok3 := next_cron_slot_region("0 9 * * 1-5", ny, "[\"2026-12-25\",\"2026-12-28\"]", 0, 0, after_ms)
	testing.expect(t, ok3, "cron eval with multi-blackout ok")
	testing.expect(t, test_format(t, next3) == "2026-12-29T14:00:00Z", "next run skips to Tuesday 09:00 EST")

	// Case 4: Active until window expired before next slot -> returns ok=false
	until_ms := (i64(days_dec24) * 86400 + 18 * 3600) * 1000 // expires Dec 24 18:00 UTC
	_, ok4 := next_cron_slot_region("0 9 * * 1-5", ny, "[]", 0, until_ms, after_ms)
	testing.expect(t, !ok4, "expired active_until should return ok=false")

	// Case 5: Active from window in future -> first slot after active_from
	from_days := days_from_civil(2027, 1, 1)
	active_from_ms := (i64(from_days) * 86400) * 1000 // 2027-01-01 is Friday
	next5, ok5 := next_cron_slot("0 9 * * 1-5", "UTC", "[]", active_from_ms, 0, after_ms)
	testing.expect(t, ok5, "active_from in future ok")
	testing.expect(t, test_format(t, next5) == "2027-01-01T09:00:00Z", "first slot is 2027-01-01 09:00 UTC")
}

@(test)
test_interval_advance :: proc(t: ^testing.T) {
    tracked(t, test_interval_advance_scenario)
}
test_interval_advance_scenario :: proc(t: ^testing.T) {
	target := i64(1_000_000)

	// 1. One-time action (interval_seconds = 0) -> completed
	next1, completed1 := advance_interval_ms(target, 0, 1_005_000)
	testing.expect(t, completed1, "one-time action must be completed")
	testing.expect(t, next1 == target, "target_run_at unchanged on completion")

	// 2. Normal recurring advance (interval = 60s)
	next2, completed2 := advance_interval_ms(target, 60, 1_000_500)
	testing.expect(t, !completed2, "recurring action must not be completed")
	testing.expect(t, next2 == 1_060_000, "next run must advance by 60s")

	// 3. Missed intervals resync
	next3, completed3 := advance_interval_ms(target, 60, 1_150_000)
	testing.expect(t, !completed3, "recurring action must not be completed")
	testing.expect(t, next3 == 1_180_000, "missed intervals must resync to next future slot (1_180_000)")
}


expect_cron :: proc(t: ^testing.T, expr, expected: string) {
    out, ok := nats_cron(expr)
    defer delete(out)
    testing.expect(t, ok)
    testing.expect_value(t, out, expected)
}

@(test)
test_nats_cron_steps_and_ranges :: proc(t: ^testing.T) {
    tracked(t, test_nats_cron_steps_and_ranges_scenario)
}
test_nats_cron_steps_and_ranges_scenario :: proc(t: ^testing.T) {
expect_cron(t, "*/15 9 * * 1-5", "0 0,15,30,45 9 * * 1,2,3,4,5")
}

@(test)
test_nats_cron_star_only_when_exact :: proc(t: ^testing.T) {
    tracked(t, test_nats_cron_star_only_when_exact_scenario)
}
test_nats_cron_star_only_when_exact_scenario :: proc(t: ^testing.T) {
expect_cron(t, "0 0 */1 * *", "0 0 0 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31 * *")
expect_cron(t, "0 0 * * */1", "0 0 0 * * 0,1,2,3,4,5,6")
expect_cron(t, "* * * * *", "0 * * * * *")
}

@(test)
test_nats_cron_dow_fold :: proc(t: ^testing.T) {
    tracked(t, test_nats_cron_dow_fold_scenario)
}
test_nats_cron_dow_fold_scenario :: proc(t: ^testing.T) {
expect_cron(t, "0 0 * * 7", "0 0 0 * * 0")
expect_cron(t, "0 0 * * 5-7", "0 0 0 * * 0,5,6")
expect_cron(t, "0 0 * * 0-7", "0 0 0 * * 0,1,2,3,4,5,6")
expect_cron(t, "0 0 * * 1,7", "0 0 0 * * 0,1")
}

@(test)
test_nats_cron_rejects_invalid :: proc(t: ^testing.T) {
    tracked(t, test_nats_cron_rejects_invalid_scenario)
}
test_nats_cron_rejects_invalid_scenario :: proc(t: ^testing.T) {
for expr in ([]string{"* * * *", "* * * * * *", "60 * * * *", "? * * * *", "*/0 * * * *", "* * * 13 *", "* * * * 8"}) {
    out, ok := nats_cron(expr)
    testing.expect(t, !ok)
    testing.expect_value(t, out, "")
}
}

@(test)
test_local_date_new_york :: proc(t: ^testing.T) {
    tracked(t, test_local_date_new_york_scenario)
}
test_local_date_new_york_scenario :: proc(t: ^testing.T) {
ny, ok := timezone.region_load_from_buffer(NY_TZIF, "America/New_York")
if !testing.expect(t, ok) do return
defer timezone.region_destroy(ny)
ms, parsed := parse_rfc3339_ms("2026-11-21T03:30:00Z")
testing.expect(t, parsed)
y, m, d := local_date_region(ms, ny)
testing.expect_value(t, y, 2026)
testing.expect_value(t, m, 11)
testing.expect_value(t, d, 20)
}

@(test)
test_timezone_valid_and_local_date :: proc(t: ^testing.T) {
    tracked(t, test_timezone_valid_and_local_date_scenario)
}
test_timezone_valid_and_local_date_scenario :: proc(t: ^testing.T) {
testing.expect(t, timezone_valid("America/New_York"), "runtime IANA zone database must be available")
for name in ([]string{"", "UTC", "America/New_York"}) {
    testing.expect(t, timezone_valid(name))
    ms, _ := parse_rfc3339_ms("2026-11-21T03:30:00Z")
    y, m, d, ok := local_date(ms, name)
    testing.expect(t, ok)
    testing.expect_value(t, y, 2026)
    testing.expect_value(t, m, 11)
    testing.expect_value(t, d, 20 if name == "America/New_York" else 21)
}
testing.expect(t, !timezone_valid("Invalid/No_Such_Zone"))
_, _, _, ok := local_date(0, "Invalid/No_Such_Zone")
testing.expect(t, !ok)
}

@(test)
test_cron_dst_gap :: proc(t: ^testing.T) {
    tracked(t, test_cron_dst_gap_scenario)
}
test_cron_dst_gap_scenario :: proc(t: ^testing.T) {
ny, ok := timezone.region_load_from_buffer(NY_TZIF, "America/New_York")
if !testing.expect(t, ok) do return
defer timezone.region_destroy(ny)
after, _ := parse_rfc3339_ms("2027-03-14T00:00:00Z")
next, found := next_cron_slot_region("30 2 * * *", ny, "[]", 0, 0, after)
testing.expect(t, found)
testing.expect_value(t, test_format(t, next), "2027-03-14T07:30:00Z")
// Characterize the copied evaluator: nats-server skips the nonexistent 02:30.

}

@(test)
test_cron_dst_overlap :: proc(t: ^testing.T) {
    tracked(t, test_cron_dst_overlap_scenario)
}
test_cron_dst_overlap_scenario :: proc(t: ^testing.T) {
ny, ok := timezone.region_load_from_buffer(NY_TZIF, "America/New_York")
if !testing.expect(t, ok) do return
defer timezone.region_destroy(ny)
after, _ := parse_rfc3339_ms("2027-11-07T00:00:00Z")
first, found := next_cron_slot_region("30 1 * * *", ny, "[]", 0, 0, after)
testing.expect(t, found)
testing.expect_value(t, test_format(t, first), "2027-11-07T05:30:00Z")
second, found2 := next_cron_slot_region("30 1 * * *", ny, "[]", 0, 0, first)
testing.expect(t, found2)
testing.expect_value(t, test_format(t, second), "2027-11-08T06:30:00Z")
// The copied evaluator selects one occurrence; nats-server fires both.

}


@(test)
test_nats_cron_explicit_allocator :: proc(t: ^testing.T) {
    tracked(t, test_nats_cron_explicit_allocator_scenario)
}
test_nats_cron_explicit_allocator_scenario :: proc(t: ^testing.T) {
    output_track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&output_track, context.allocator)
    defer mem.tracking_allocator_destroy(&output_track)
    allocator := mem.tracking_allocator(&output_track)
    out, ok := nats_cron("*/15 9 * * 1-5", allocator)
    testing.expect(t, ok)
    testing.expect(t, len(output_track.allocation_map) > 0)
    delete(out, allocator)
    testing.expect_value(t, len(output_track.allocation_map), 0)
}

@(test)
test_local_date_before_epoch :: proc(t: ^testing.T) {
    tracked(t, test_local_date_before_epoch_scenario)
}
test_local_date_before_epoch_scenario :: proc(t: ^testing.T) {
    y, m, d, ok := local_date(-1, "UTC")
    testing.expect(t, ok)
    testing.expect_value(t, y, 1969)
    testing.expect_value(t, m, 12)
    testing.expect_value(t, d, 31)
}
