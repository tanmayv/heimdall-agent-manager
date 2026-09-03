package bridge_prompt_scheduler_test

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

check :: proc(ok: bool, msg: string) {
	if ok do return
	fmt.eprintln("FAIL:", msg)
	os.exit(1)
}

prompt_scheduler_days_from_civil :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) %% 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

prompt_scheduler_parse_rfc3339_ms :: proc(s: string) -> (i64, bool) {
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
	days := prompt_scheduler_days_from_civil(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

prompt_scheduler_parse_interval_seconds :: proc(interval: string) -> int {
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

prompt_scheduler_is_due :: proc(target_run_at_ms, now_ms: i64) -> bool {
	return target_run_at_ms > 0 && now_ms >= target_run_at_ms
}

Prompt_Queue_Item :: struct {
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

prompt_scheduler_can_claim :: proc(item: Prompt_Queue_Item, now_ms: i64, lease_window_ms: i64 = 60_000) -> bool {
	if item.state == "completed" do return false
	if !prompt_scheduler_is_due(item.target_run_at_ms, now_ms) do return false
	if !item.in_flight do return true
	if lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) do return true
	return false
}

prompt_scheduler_claim :: proc(item: ^Prompt_Queue_Item, now_ms: i64) {
	if item == nil do return
	item.in_flight = true
	item.leased_at_ms = now_ms
	item.state = "in_flight"
}

prompt_scheduler_recover_lease :: proc(item: ^Prompt_Queue_Item, now_ms: i64, lease_window_ms: i64 = 60_000) -> bool {
	if item == nil do return false
	if item.in_flight && lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) {
		item.in_flight = false
		item.state = "active"
		return true
	}
	return false
}

prompt_scheduler_advance_ms :: proc(target_run_at_ms: i64, interval_seconds: int, now_ms: i64) -> (next_run_ms: i64, completed: bool) {
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

main :: proc() {
	// 1. Test interval parsing
	check(prompt_scheduler_parse_interval_seconds("60s") == 60, "60s == 60")
	check(prompt_scheduler_parse_interval_seconds("30s") == 30, "30s == 30")
	check(prompt_scheduler_parse_interval_seconds("5m") == 300, "5m == 300")
	check(prompt_scheduler_parse_interval_seconds("2h") == 7200, "2h == 7200")
	check(prompt_scheduler_parse_interval_seconds("1d") == 86400, "1d == 86400")
	check(prompt_scheduler_parse_interval_seconds("90") == 90, "90 == 90")
	check(prompt_scheduler_parse_interval_seconds("") == 0, "empty == 0")
	check(prompt_scheduler_parse_interval_seconds("invalid") == 0, "invalid == 0")

	// 2. Test RFC3339 parsing
	ms_epoch, epoch_ok := prompt_scheduler_parse_rfc3339_ms("1970-01-01T00:00:00Z")
	check(epoch_ok && ms_epoch == 0, "epoch timestamp parsing")

	ms_2026, y2026_ok := prompt_scheduler_parse_rfc3339_ms("2026-01-01T00:00:00Z")
	check(y2026_ok && ms_2026 > 0, "2026 timestamp parsing")

	// 3. Test timing due check
	check(!prompt_scheduler_is_due(1000, 500), "not due before target")
	check(prompt_scheduler_is_due(1000, 1000), "due at target")
	check(prompt_scheduler_is_due(1000, 1500), "due after target")

	// 4. Test claim & lease recovery logic
	now := i64(500_000)
	item := Prompt_Queue_Item{
		id = "sp_test_1",
		target_instance_id = "inst_1",
		target_run_at_ms = 400_000,
		state = "active",
		in_flight = false,
		leased_at_ms = 0,
	}

	check(prompt_scheduler_can_claim(item, now), "active prompt can be claimed")

	// Claim item
	prompt_scheduler_claim(&item, now)
	check(item.in_flight == true, "item is in_flight")
	check(item.state == "in_flight", "item state is in_flight")
	check(item.leased_at_ms == now, "item leased_at is now")
	check(!prompt_scheduler_can_claim(item, now + 10_000), "cannot claim in-flight item within lease window")

	// Lease recovery: before lease window -> no change
	check(!prompt_scheduler_recover_lease(&item, now + 30_000, 60_000), "should not recover lease before window")
	check(item.in_flight == true, "item still in_flight")

	// Lease recovery: after lease window (70s) -> recovered!
	check(prompt_scheduler_recover_lease(&item, now + 70_000, 60_000), "recovers lease after window")
	check(item.in_flight == false, "item no longer in_flight")
	check(item.state == "active", "item state back to active")
	check(prompt_scheduler_can_claim(item, now + 70_000), "can claim recovered item")

	// 5. Test advance logic
	// One-time prompt completes
	t0 := i64(1_000_000)
	next_once, comp_once := prompt_scheduler_advance_ms(t0, 0, t0 + 5000)
	check(comp_once, "one-time prompt marked completed")
	check(next_once == t0, "one-time target unchanged")

	// Recurring prompt advances by interval
	next_rec, comp_rec := prompt_scheduler_advance_ms(t0, 60, t0 + 500)
	check(!comp_rec, "recurring prompt not completed")
	check(next_rec == t0 + 60_000, "recurring prompt advanced by 60s")

	// Recurring prompt with missed intervals fires once and resyncs to next future slot
	// Missed 2.5 intervals: now is t0 + 150_000. Expected next is t0 + 180_000.
	next_missed, comp_missed := prompt_scheduler_advance_ms(t0, 60, t0 + 150_000)
	check(!comp_missed, "missed interval prompt not completed")
	check(next_missed == t0 + 180_000, "missed interval prompt resynced to next future slot")

	fmt.println("ALL BRIDGE PROMPT SCHEDULER TESTS PASSED")
}
