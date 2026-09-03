package bridge_action_scheduler_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

action_scheduler_days_from_civil :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) %% 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

action_scheduler_civil_from_days :: proc(z: int) -> (year: int, month: int, day: int) {
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

action_scheduler_weekday_from_days :: proc(days: int) -> int {
	w := (days + 4) %% 7
	if w < 0 do w += 7
	return w
}

action_scheduler_format_rfc3339_utc :: proc(ms: i64) -> string {
	secs := ms / 1000
	days := int(secs / 86400)
	rem_secs := int(secs % 86400)
	if rem_secs < 0 {
		rem_secs += 86400
		days -= 1
	}
	y, m, d := action_scheduler_civil_from_days(days)
	hour := rem_secs / 3600
	minute := (rem_secs % 3600) / 60
	second := rem_secs % 60
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, hour, minute, second)
}

action_scheduler_parse_rfc3339_ms :: proc(s: string) -> (i64, bool) {
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
	days := action_scheduler_days_from_civil(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

action_scheduler_parse_interval_seconds :: proc(interval: string) -> int {
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

Parsed_Cron :: struct {
	minutes:         [60]bool,
	hours:           [24]bool,
	dom:             [32]bool,
	months:          [13]bool,
	dow:             [8]bool,
	dom_is_wildcard: bool,
	dow_is_wildcard: bool,
}

action_scheduler_parse_cron_field :: proc(field: string, min_val, max_val: int, bits: ^[]bool) -> bool {
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

action_scheduler_parse_cron :: proc(expr: string) -> (cron: Parsed_Cron, ok: bool) {
	parts := strings.fields(strings.trim_space(expr))
	defer delete(parts)
	if len(parts) != 5 do return {}, false
	min_slice := cron.minutes[:]
	hour_slice := cron.hours[:]
	dom_slice := cron.dom[:]
	mo_slice := cron.months[:]
	dow_slice := cron.dow[:]
	if !action_scheduler_parse_cron_field(parts[0], 0, 59, &min_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[1], 0, 23, &hour_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[2], 1, 31, &dom_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[3], 1, 12, &mo_slice) do return {}, false
	if !action_scheduler_parse_cron_field(parts[4], 0, 7, &dow_slice) do return {}, false
	if cron.dow[0] do cron.dow[7] = true
	if cron.dow[7] do cron.dow[0] = true
	cron.dom_is_wildcard = (parts[2] == "*")
	cron.dow_is_wildcard = (parts[4] == "*")
	return cron, true
}

action_scheduler_is_blackout_date :: proc(blackout_json: string, year, month, day: int) -> bool {
	if blackout_json == "" || blackout_json == "[]" do return false
	needle := fmt.tprintf("\"%04d-%02d-%02d\"", year, month, day)
	return strings.contains(blackout_json, needle)
}

action_scheduler_eval_next_cron_slot :: proc(
	cron_expr: string,
	tz_name: string,
	blackout_json: string,
	active_from_ms: i64,
	active_until_ms: i64,
	after_ms: i64,
) -> (next_ms: i64, ok: bool) {
	cron, cron_ok := action_scheduler_parse_cron(cron_expr)
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

	curr_days := action_scheduler_days_from_civil(int(dt_local.year), int(dt_local.month), int(dt_local.day))

	for day_offset in 0..=730 {
		y, m, d := action_scheduler_civil_from_days(curr_days + day_offset)
		if action_scheduler_is_blackout_date(blackout_json, y, m, d) do continue
		if !cron.months[m] do continue

		dow := action_scheduler_weekday_from_days(curr_days + day_offset)
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

action_scheduler_advance_interval_ms :: proc(target_run_at_ms: i64, interval_seconds: int, now_ms: i64) -> (next_run_ms: i64, completed: bool) {
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

Action_Queue_Item :: struct {
	id:                 string,
	target_instance_id: string,
	prompt_text:        string,
	target_run_at:      string,
	target_run_at_ms:   i64,
	interval:           string,
	interval_seconds:   int,
	state:              string,
	in_flight:          bool,
	leased_at_ms:       i64,
}

action_scheduler_is_due :: proc(target_run_at_ms, now_ms: i64) -> bool {
	return target_run_at_ms > 0 && now_ms >= target_run_at_ms
}

action_scheduler_can_claim :: proc(item: Action_Queue_Item, now_ms: i64, lease_window_ms: i64 = 60_000) -> bool {
	if item.state == "completed" do return false
	if !action_scheduler_is_due(item.target_run_at_ms, now_ms) do return false
	if !item.in_flight do return true
	if lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) do return true
	return false
}

action_scheduler_claim :: proc(item: ^Action_Queue_Item, now_ms: i64) {
	if item == nil do return
	item.in_flight = true
	item.leased_at_ms = now_ms
	item.state = "in_flight"
}

action_scheduler_recover_lease :: proc(item: ^Action_Queue_Item, now_ms: i64, lease_window_ms: i64 = 60_000) -> bool {
	if item == nil do return false
	if item.in_flight && lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) {
		item.in_flight = false
		item.state = "active"
		return true
	}
	return false
}

main :: proc() {
	// 1. Interval parser test
	check(action_scheduler_parse_interval_seconds("60s") == 60, "60s == 60")
	check(action_scheduler_parse_interval_seconds("30s") == 30, "30s == 30")
	check(action_scheduler_parse_interval_seconds("5m") == 300, "5m == 300")
	check(action_scheduler_parse_interval_seconds("2h") == 7200, "2h == 7200")
	check(action_scheduler_parse_interval_seconds("1d") == 86400, "1d == 86400")
	check(action_scheduler_parse_interval_seconds("90") == 90, "90 == 90")
	check(action_scheduler_parse_interval_seconds("") == 0, "empty == 0")
	check(action_scheduler_parse_interval_seconds("invalid") == 0, "invalid == 0")

	// 2. RFC3339 parser & formatter test
	ms_epoch, epoch_ok := action_scheduler_parse_rfc3339_ms("1970-01-01T00:00:00Z")
	check(epoch_ok && ms_epoch == 0, "epoch ms == 0")
	ms_2026, y2026_ok := action_scheduler_parse_rfc3339_ms("2026-01-01T00:00:00Z")
	check(y2026_ok && ms_2026 > 0, "2026 parse ok")
	fmt_ts := action_scheduler_format_rfc3339_utc(ms_2026)
	check(fmt_ts == "2026-01-01T00:00:00Z", "format matches original timestamp")

	// 3. Timing / Due check
	check(!action_scheduler_is_due(1000, 500), "not due before target")
	check(action_scheduler_is_due(1000, 1000), "due at target")
	check(action_scheduler_is_due(1000, 1500), "due after target")
	check(!action_scheduler_is_due(0, 1500), "not due if 0")

	// 4. Cron Evaluator Tests (Pure cron + timezone + blackout next-slot logic)
	// 2026-12-24 is Thursday.
	days_dec24 := action_scheduler_days_from_civil(2026, 12, 24)
	after_ms := (i64(days_dec24) * 86400 + 15 * 3600) * 1000 // 15:00 UTC (10:00 EST)

	// 4a. Weekday schedule: next slot is Friday Dec 25 at 09:00 EST (14:00 UTC)
	next1, ok1 := action_scheduler_eval_next_cron_slot("0 9 * * 1-5", "America/New_York", "[]", 0, 0, after_ms)
	check(ok1, "cron eval ok")
	check(action_scheduler_format_rfc3339_utc(next1) == "2026-12-25T14:00:00Z", "next run is Friday 09:00 EST")

	// 4b. Holiday blackout on Friday Dec 25: skips Friday + weekend, lands on Monday Dec 28 09:00 EST (14:00 UTC)
	next2, ok2 := action_scheduler_eval_next_cron_slot("0 9 * * 1-5", "America/New_York", "[\"2026-12-25\"]", 0, 0, after_ms)
	check(ok2, "cron eval with holiday blackout ok")
	check(action_scheduler_format_rfc3339_utc(next2) == "2026-12-28T14:00:00Z", "next run skips Friday + weekend to Monday 09:00 EST")

	// 4c. Multi-blackout on Friday Dec 25 AND Monday Dec 28: skips to Tuesday Dec 29 09:00 EST (14:00 UTC)
	next3, ok3 := action_scheduler_eval_next_cron_slot("0 9 * * 1-5", "America/New_York", "[\"2026-12-25\",\"2026-12-28\"]", 0, 0, after_ms)
	check(ok3, "cron eval with multi-blackout ok")
	check(action_scheduler_format_rfc3339_utc(next3) == "2026-12-29T14:00:00Z", "next run skips to Tuesday 09:00 EST")

	// 4d. Active until window expired: candidate slot past active_until returns false
	until_ms := (i64(days_dec24) * 86400 + 18 * 3600) * 1000 // expires Dec 24 18:00 UTC
	_, ok4 := action_scheduler_eval_next_cron_slot("0 9 * * 1-5", "America/New_York", "[]", 0, until_ms, after_ms)
	check(!ok4, "expired active_until returns ok=false")

	// 4e. Weekend skip test: from Friday 18:00 EST (23:00 UTC), next run is Monday 09:00 EST
	fri_ms := (i64(days_dec24 + 1) * 86400 + 23 * 3600) * 1000
	next_wknd, ok_wknd := action_scheduler_eval_next_cron_slot("0 9 * * 1-5", "America/New_York", "[]", 0, 0, fri_ms)
	check(ok_wknd, "weekend skip eval ok")
	check(action_scheduler_format_rfc3339_utc(next_wknd) == "2026-12-28T14:00:00Z", "weekend is skipped to Monday 09:00 EST")

	// 5. Claim & Lease recovery tests
	now := i64(500_000)
	item := Action_Queue_Item{
		id = "act_test_1",
		target_instance_id = "inst_1",
		target_run_at_ms = 450_000,
		state = "active",
		in_flight = false,
		leased_at_ms = 0,
	}

	check(action_scheduler_can_claim(item, now), "active action can be claimed")
	action_scheduler_claim(&item, now)
	check(item.in_flight == true && item.state == "in_flight", "item claimed")
	check(!action_scheduler_can_claim(item, now + 10_000), "cannot claim in-flight item within lease window")

	check(!action_scheduler_recover_lease(&item, now + 30_000, 60_000), "should not recover lease before window")
	check(item.in_flight == true, "still in_flight")

	check(action_scheduler_recover_lease(&item, now + 70_000, 60_000), "recovers lease after window")
	check(item.in_flight == false && item.state == "active", "item reset to active")
	check(action_scheduler_can_claim(item, now + 70_000), "can claim recovered item")

	// 6. Interval advance tests
	t0 := i64(1_000_000)
	next_once, comp_once := action_scheduler_advance_interval_ms(t0, 0, t0 + 5000)
	check(comp_once && next_once == t0, "0 interval completes")

	next_rec, comp_rec := action_scheduler_advance_interval_ms(t0, 60, t0 + 500)
	check(!comp_rec && next_rec == t0 + 60_000, "recurring interval advances by 60s")

	next_missed, comp_missed := action_scheduler_advance_interval_ms(t0, 60, t0 + 150_000)
	check(!comp_missed && next_missed == t0 + 180_000, "missed interval resyncs to next future slot")

	fmt.println("ALL BRIDGE ACTION SCHEDULER TESTS PASSED")
}
