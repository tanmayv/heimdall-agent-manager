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

format_rfc3339_utc :: proc(t: time.Time) -> string {
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", year, int(month), day, hour, minute, second)
}
