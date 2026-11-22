package schedule

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

// Pure evaluator ported from the bridge scheduler; scheduling behavior is unchanged.
days_from_civil :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) %% 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

civil_from_days :: proc(z: int) -> (year: int, month: int, day: int) {
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

weekday_from_days :: proc(days: int) -> int {
	w := (days + 4) %% 7
	if w < 0 do w += 7
	return w
}

format_rfc3339_utc :: proc(ms: i64) -> string {
	secs := ms / 1000
	days := int(secs / 86400)
	rem_secs := int(secs % 86400)
	if rem_secs < 0 {
		rem_secs += 86400
		days -= 1
	}
	y, m, d := civil_from_days(days)
	hour := rem_secs / 3600
	minute := (rem_secs % 3600) / 60
	second := rem_secs % 60
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hour, minute, second)
}

// Parses hub UTC RFC3339 timestamp (YYYY-MM-DDTHH:MM:SSZ) to unix milliseconds.
parse_rfc3339_ms :: proc(s: string) -> (i64, bool) {
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
	year, y_ok := parse4(t[0:4])
	month, mo_ok := parse2(t[5:7])
	day, d_ok := parse2(t[8:10])
	hour, h_ok := parse2(t[11:13])
	minute, mi_ok := parse2(t[14:16])
	second, s_ok := parse2(t[17:19])
	if !(y_ok && mo_ok && d_ok && h_ok && mi_ok && s_ok) do return 0, false
	if month < 1 || month > 12 do return 0, false
	days := days_from_civil(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

parse_interval_seconds :: proc(interval: string) -> int {
	s := strings.trim_space(interval)
	if len(s) == 0 do return 0
	unit := s[len(s)-1]
	val_str := s[:len(s)-1]
	val, ok := strconv.parse_int(val_str)
	if !ok || val <= 0 do return 0
	switch unit {
	case 's': return val
	case 'm': return val * 60
	case 'h': return val * 3600
	case 'd': return val * 86400
	case:
		num, num_ok := strconv.parse_int(s)
		if num_ok && num > 0 do return num
		return 0
	}
}

// --- Cron Parser & Evaluator ---

Parsed_Cron :: struct {
	minutes:         [60]bool,
	hours:           [24]bool,
	dom:             [32]bool,
	months:          [13]bool,
	dow:             [8]bool,
	dom_is_wildcard: bool,
	dow_is_wildcard: bool,
}

parse_cron_field :: proc(field: string, min_val, max_val: int, bits: ^[]bool) -> bool {
	f := strings.trim_space(field)
	if f == "" do return false
	if f == "*" {
		for i in min_val..=max_val do bits[i] = true
		return true
	}
	subparts := strings.split(f, ",")
	defer delete(subparts)
	for sp in subparts {
		s := strings.trim_space(sp)
		if s == "" do return false
		if strings.contains(s, "/") {
			slash_parts := strings.split(s, "/")
			defer delete(slash_parts)
			if len(slash_parts) != 2 do return false
			step, ok := strconv.parse_int(slash_parts[1])
			if !ok || step <= 0 do return false
			base := slash_parts[0]
			start_val := min_val
			end_val := max_val
			if base != "*" {
				if strings.contains(base, "-") {
					dash_parts := strings.split(base, "-")
					defer delete(dash_parts)
					if len(dash_parts) != 2 do return false
					v1, ok1 := strconv.parse_int(dash_parts[0])
					v2, ok2 := strconv.parse_int(dash_parts[1])
					if !ok1 || !ok2 || v1 < min_val || v2 > max_val || v1 > v2 do return false
					start_val = v1
					end_val = v2
				} else {
					v, ok_v := strconv.parse_int(base)
					if !ok_v || v < min_val || v > max_val do return false
					start_val = v
					end_val = max_val
				}
			}
			for v := start_val; v <= end_val; v += step do bits[v] = true
		} else if strings.contains(s, "-") {
			dash_parts := strings.split(s, "-")
			defer delete(dash_parts)
			if len(dash_parts) != 2 do return false
			v1, ok1 := strconv.parse_int(dash_parts[0])
			v2, ok2 := strconv.parse_int(dash_parts[1])
			if !ok1 || !ok2 || v1 < min_val || v2 > max_val || v1 > v2 do return false
			for v in v1..=v2 do bits[v] = true
		} else {
			v, ok_v := strconv.parse_int(s)
			if !ok_v || v < min_val || v > max_val do return false
			bits[v] = true
		}
	}
	return true
}

parse_cron :: proc(expr: string) -> (cron: Parsed_Cron, ok: bool) {
	parts := strings.fields(strings.trim_space(expr))
	defer delete(parts)
	if len(parts) != 5 do return {}, false
	min_slice := cron.minutes[:]
	hour_slice := cron.hours[:]
	dom_slice := cron.dom[:]
	mo_slice := cron.months[:]
	dow_slice := cron.dow[:]
	if !parse_cron_field(parts[0], 0, 59, &min_slice) do return {}, false
	if !parse_cron_field(parts[1], 0, 23, &hour_slice) do return {}, false
	if !parse_cron_field(parts[2], 1, 31, &dom_slice) do return {}, false
	if !parse_cron_field(parts[3], 1, 12, &mo_slice) do return {}, false
	if !parse_cron_field(parts[4], 0, 7, &dow_slice) do return {}, false
	if cron.dow[0] do cron.dow[7] = true
	if cron.dow[7] do cron.dow[0] = true
	cron.dom_is_wildcard = (parts[2] == "*")
	cron.dow_is_wildcard = (parts[4] == "*")
	return cron, true
}

is_blackout_date :: proc(blackout_json: string, year, month, day: int) -> bool {
	if blackout_json == "" || blackout_json == "[]" do return false
	needle := fmt.tprintf("\"%04d-%02d-%02d\"", year, month, day)
	return strings.contains(blackout_json, needle)
}

// Given cron expression, IANA timezone, blackout dates, active window, and after_ms reference time,
// computes the next valid fire slot in UTC milliseconds, skipping blackout dates and cron-excluded days.
next_cron_slot :: proc(
	cron_expr: string,
	tz_name: string,
	blackout_json: string,
	active_from_ms: i64,
	active_until_ms: i64,
	after_ms: i64,
) -> (next_ms: i64, ok: bool) {
	_, cron_ok := parse_cron(cron_expr)
	if !cron_ok do return 0, false

	tz_clean := strings.trim_space(tz_name)
	reg: ^datetime.TZ_Region = nil
	has_tz := false
	if tz_clean != "" && tz_clean != "UTC" {
		reg, has_tz = timezone.region_load(tz_clean)
	}
	defer {
		if has_tz && reg != nil {
			timezone.region_destroy(reg)
		}
	}

	return next_cron_slot_region(cron_expr, reg, blackout_json, active_from_ms, active_until_ms, after_ms)
}

// Same as next_cron_slot but with an already-loaded timezone region
// (nil = UTC); the caller owns reg. Lets tests inject an embedded TZif instead of host tzdata.
next_cron_slot_region :: proc(
	cron_expr: string,
	reg: ^datetime.TZ_Region,
	blackout_json: string,
	active_from_ms: i64,
	active_until_ms: i64,
	after_ms: i64,
) -> (next_ms: i64, ok: bool) {
	cron, cron_ok := parse_cron(cron_expr)
	if !cron_ok do return 0, false

	ref_ms := after_ms
	if active_from_ms > 0 && active_from_ms > ref_ms {
		ref_ms = active_from_ms - 1000
	}

	secs := ref_ms / 1000
	tm_ref := time.unix(secs, 0)
	dt_utc, dt_ok := time.time_to_datetime(tm_ref)
	if !dt_ok do return 0, false
	dt_local, local_ok := timezone.datetime_to_tz(dt_utc, reg)
	if !local_ok do return 0, false

	curr_days := days_from_civil(int(dt_local.year), int(dt_local.month), int(dt_local.day))

	// Search up to 2 years (730 days) forward
	for day_offset in 0..=730 {
		y, m, d := civil_from_days(curr_days + day_offset)
		if is_blackout_date(blackout_json, y, m, d) do continue
		if !cron.months[m] do continue

		dow := weekday_from_days(curr_days + day_offset)
		dom_match := cron.dom[d]
		dow_match := cron.dow[dow]
		day_matches := false
		if cron.dom_is_wildcard && cron.dow_is_wildcard {
			day_matches = true
		} else if !cron.dom_is_wildcard && cron.dow_is_wildcard {
			day_matches = dom_match
		} else if cron.dom_is_wildcard && !cron.dow_is_wildcard {
			day_matches = dow_match
		} else {
			day_matches = (dom_match || dow_match)
		}
		if !day_matches do continue

		for h in 0..=23 {
			if !cron.hours[h] do continue
			for mi in 0..=59 {
				if !cron.minutes[mi] do continue

				cand_dt := datetime.DateTime{
					date = datetime.Date{year = i64(y), month = i8(m), day = i8(d)},
					time = datetime.Time{hour = i8(h), minute = i8(mi), second = 0},
					tz = reg,
				}
				cand_utc, utc_ok := timezone.datetime_to_utc(cand_dt)
				if !utc_ok do continue
				cand_tm, tm_ok := time.datetime_to_time(cand_utc)
				if !tm_ok do continue
				cand_ms := time.time_to_unix(cand_tm) * 1000

				if cand_ms <= after_ms do continue
				if active_from_ms > 0 && cand_ms < active_from_ms do continue
				if active_until_ms > 0 && cand_ms > active_until_ms do return 0, false

				return cand_ms, true
			}
		}
	}

	return 0, false
}

advance_interval_ms :: proc(target_run_at_ms: i64, interval_seconds: int, now_ms: i64) -> (next_run_ms: i64, completed: bool) {
	if interval_seconds <= 0 {
		return target_run_at_ms, true
	}
	interval_ms := i64(interval_seconds) * 1000
	next := target_run_at_ms + interval_ms
	for next <= now_ms {
		next += interval_ms
	}
	return next, false
}


// UTC and the empty name need no timezone allocation.
timezone_valid :: proc(name: string) -> bool {
    if name == "" || name == "UTC" do return true
    reg, ok := timezone.region_load(name)
    if ok do timezone.region_destroy(reg)
    return ok
}

local_date :: proc(ms: i64, tz_name: string) -> (year, month, day: int, ok: bool) {
    reg: ^datetime.TZ_Region
    if tz_name != "" && tz_name != "UTC" {
        loaded: bool
        reg, loaded = timezone.region_load(tz_name)
        if !loaded do return 0, 0, 0, false
    }
    defer if reg != nil do timezone.region_destroy(reg)
    year, month, day = local_date_region(ms, reg)
    return year, month, day, true
}

// reg is borrowed; nil denotes UTC.
local_date_region :: proc(ms: i64, reg: ^datetime.TZ_Region) -> (year, month, day: int) {
    secs := ms / 1000
    if ms < 0 && ms % 1000 != 0 do secs -= 1
    dt, _ := time.time_to_datetime(time.unix(secs, 0))
    local, _ := timezone.datetime_to_tz(dt, reg)
    return int(local.year), int(local.month), int(local.day)
}
