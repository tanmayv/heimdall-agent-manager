package main

import "core:fmt"

bridge_civil_from_days :: proc(z: int) -> (year: int, month: int, day: int) {
	z_shifted := z + 719468
	era := (z_shifted if z_shifted >= 0 else z_shifted - 146096) / 146097
	doe := z_shifted - era * 146097
	yoe := (doe - doe/1460 + doe/36524 - doe/146096) / 365
	y := yoe + era * 400
	doy := doe - (365*yoe + yoe/4 - yoe/100)
	mp := (5*doy + 2)/153
	d := doy - (153*mp + 2)/5 + 1
	m := mp + 3 if mp < 10 else mp - 9
	return y + (1 if m <= 2 else 0), m, d
}

// Returns a whole-second UTC timestamp in context.temp_allocator.
bridge_format_rfc3339_utc_ms :: proc(ms: i64) -> string {
	secs := ms / 1000
	days := int(secs / 86400)
	rem_secs := int(secs % 86400)
	if rem_secs < 0 {
		rem_secs += 86400
		days -= 1
	}
	y, m, d := bridge_civil_from_days(days)
	hour := rem_secs / 3600
	minute := (rem_secs % 3600) / 60
	second := rem_secs % 60
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hour, minute, second)
}
