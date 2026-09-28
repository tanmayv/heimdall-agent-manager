package platform

import "core:fmt"
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
