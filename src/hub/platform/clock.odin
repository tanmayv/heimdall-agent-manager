package platform

import "core:fmt"
import "core:strings"
import "core:time"

Clock_Now_Proc :: proc(ctx: rawptr) -> string

Clock :: struct {
	ctx: Clock_Context,
	now: Clock_Now_Proc,
}

Clock_Context :: rawptr

clock_now :: proc(clock: ^Clock) -> string {
	if clock == nil || clock.now == nil do return ""
	return clock.now(rawptr(clock.ctx))
}

real_clock :: proc() -> Clock {
	return Clock{ctx = nil, now = real_clock_now}
}

real_clock_now :: proc(ctx: rawptr) -> string {
	_ = ctx
	return format_rfc3339_utc(time.now())
}

expires_at_after_seconds :: proc(seconds: int) -> string {
	delta_seconds := seconds
	if delta_seconds < 0 do delta_seconds = 0
	expires := time.time_add(time.now(), time.Duration(delta_seconds) * time.Second)
	return format_rfc3339_utc(expires)
}

// parse_rfc3339_utc is format_rfc3339_utc's inverse, and the only one in the hub:
// before this, the sole RFC3339 parser lived in the HTTP transport layer
// (rfc3339_unix_ms in content_handlers.odin), which a service cannot reach without
// depending upward on its own caller. It belongs beside the formatter instead.
//
// `consumed == 0` is core:time's spelling of "this did not parse", and a value that
// did not parse must NOT come back as a plausible-looking zero Time: every caller so
// far uses the result to build a deletion cutoff, where silently yielding the epoch
// would select every row in the table. Hence the explicit ok.
parse_rfc3339_utc :: proc(value: string) -> (time.Time, bool) {
	t, consumed := time.rfc3339_to_time_utc(value)
	if consumed == 0 do return time.Time{}, false
	return t, true
}

format_rfc3339_utc :: proc(t: time.Time) -> string {
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, minute, second)
}

// rfc3339_to_unix_ms parses the hub's canonical "YYYY-MM-DDTHH:MM:SSZ" UTC timestamp
// into unix milliseconds. It is the exact inverse of format_rfc3339_utc above, which is
// why it belongs here: every timestamp in the hub is produced by clock_now, so the proc
// that reads one back belongs next to the proc that writes it.
//
// IT IS HERE BECAUSE IT WAS ALREADY WRITTEN TWICE (REQ-SHELL-9 boy-scout). Identical
// implementations lived in agent_service (rfc3339_to_unix_ms) and content
// (platform_rfc3339_to_unix_ms), the latter carrying the comment "kept local to the
// content package to avoid a cross-service dependency" — a real constraint, and one that
// disappears the moment the parser lives in platform, which every service already
// imports. Both are now one-line delegations to this, and REQ-SHELL-9's age reap uses it
// rather than adding a third copy.
//
// IF YOU UNIFY DUPLICATE PROCS ANYWHERE IN THIS CODEBASE, DIFF THE BODIES FIRST and
// enumerate every divergence in the commit message. Consolidating two copies silently
// picks ONE spelling of every difference between them, and only the differences someone
// thinks to diff get announced. This proc is the worked example: its two copies were
// handed off as byte-identical and differed in at least TWO ways -- the length check
// below, and the month shift in days_from_civil. Both benign; neither was noticed by
// the author.
//
// The two copies had DIVERGED, which is the argument for unifying them rather than
// living with the duplication: agent's required at least 20 characters, content's only
// 19, so a timestamp missing its trailing Z parsed in one service and not the other.
// This takes the stricter reading. Every timestamp in the hub comes from
// format_rfc3339_utc and is exactly 20 characters, so the laxer check only ever admitted
// input the hub does not produce.
//
// TO BE PRECISE ABOUT WHAT THAT CHECK IS: it is a LENGTH check, not a validation of the
// trailing Z. t[19] is never examined, so "2026-09-29T04:00:00X" parses happily as UTC.
// That is harmless for hub-generated input, which is the only input this proc is for, but
// nobody should read `len(t) < 20` as proof the value is Zulu-terminated.
//
// Returns ok=false for empty or malformed input, deliberately, so a caller SKIPS rather
// than misclassifies. Every consumer is a reaper or a nudge deciding whether something
// is old enough to act on, and guessing an age from a timestamp that could not be read
// means acting on the wrong rows. Only the fixed hub format is handled; this is not a
// general RFC3339 parser and should not become one.
rfc3339_to_unix_ms :: proc(s: string) -> (i64, bool) {
	t := strings.trim_space(s)
	if len(t) < 20 do return 0, false
	if t[4] != '-' || t[7] != '-' || t[10] != 'T' || t[13] != ':' || t[16] != ':' do return 0, false
	parse2 :: proc(str: string) -> (int, bool) {
		if len(str) < 2 do return 0, false
		a := int(str[0]) - '0'; b := int(str[1]) - '0'
		if a < 0 || a > 9 || b < 0 || b > 9 do return 0, false
		return a*10 + b, true
	}
	parse4 :: proc(str: string) -> (int, bool) {
		hi, ok1 := parse2(str[0:2]); lo, ok2 := parse2(str[2:4])
		if !ok1 || !ok2 do return 0, false
		return hi*100 + lo, true
	}
	year,   y_ok  := parse4(t[0:4])
	month,  mo_ok := parse2(t[5:7])
	day,    d_ok  := parse2(t[8:10])
	hour,   h_ok  := parse2(t[11:13])
	minute, mi_ok := parse2(t[14:16])
	second, s_ok  := parse2(t[17:19])
	if !(y_ok && mo_ok && d_ok && h_ok && mi_ok && s_ok) do return 0, false
	if month < 1 || month > 12 do return 0, false
	// Days from the Unix epoch to the given date (proleptic Gregorian), then the
	// time of day. Uses Howard Hinnant's constant-time civil-from-date algorithm.
	days := days_from_civil(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

// days_from_civil returns days since 1970-01-01 for a proleptic Gregorian date.
// Based on Howard Hinnant's well-known constant-time algorithm.
//
// m MUST be 1..12. rfc3339_to_unix_ms is the only caller and it rejects any month
// outside that range before calling, so the requirement holds by construction today.
// It is written down because the month shift below has no modulo: the two unified
// copies of this proc spelled it differently — agent's used `(m + 9) %% 12`, which
// wraps, and this one does not — so the two agree for every m in 1..12 and diverge
// from m >= 15 upward. Unreachable, not harmless: anyone making this proc callable
// from somewhere that does not pre-validate the month must add the range check here.
days_from_civil :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	doy := (153 * (m + (-3 if m > 2 else 9)) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}
