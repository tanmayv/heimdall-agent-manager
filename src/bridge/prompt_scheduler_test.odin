package main

import "core:testing"

@(test)
test_prompt_scheduler_parse_interval :: proc(t: ^testing.T) {
	testing.expect(t, prompt_scheduler_parse_interval_seconds("60s") == 60, "60s should be 60")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("30s") == 30, "30s should be 30")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("5m") == 300, "5m should be 300")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("2h") == 7200, "2h should be 7200")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("1d") == 86400, "1d should be 86400")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("90") == 90, "bare 90 should be 90")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("") == 0, "empty should be 0")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("abc") == 0, "abc should be 0")
	testing.expect(t, prompt_scheduler_parse_interval_seconds("-10s") == 0, "negative should be 0")
}

@(test)
test_prompt_scheduler_parse_rfc3339 :: proc(t: ^testing.T) {
	ms, ok := prompt_scheduler_parse_rfc3339_ms("1970-01-01T00:00:00Z")
	testing.expect(t, ok, "parse unix epoch ok")
	testing.expect(t, ms == 0, "unix epoch should be 0 ms")

	ms2, ok2 := prompt_scheduler_parse_rfc3339_ms("2026-01-01T00:00:00Z")
	testing.expect(t, ok2, "parse 2026 ok")
	testing.expect(t, ms2 > 0, "2026 ms should be positive")

	_, ok3 := prompt_scheduler_parse_rfc3339_ms("invalid")
	testing.expect(t, !ok3, "invalid format should fail")

	_, ok4 := prompt_scheduler_parse_rfc3339_ms("2026-13-01T00:00:00Z")
	testing.expect(t, !ok4, "month 13 should fail")
}

@(test)
test_prompt_scheduler_is_due :: proc(t: ^testing.T) {
	target := i64(1000)
	testing.expect(t, !prompt_scheduler_is_due(target, 500), "not due before target")
	testing.expect(t, prompt_scheduler_is_due(target, 1000), "due at target")
	testing.expect(t, prompt_scheduler_is_due(target, 1500), "due after target")
	testing.expect(t, !prompt_scheduler_is_due(0, 1500), "not due if target is 0")
}

@(test)
test_prompt_scheduler_can_claim :: proc(t: ^testing.T) {
	now := i64(100_000)
	item := Prompt_Queue_Item{
		id = "sp_1",
		target_instance_id = "inst_1",
		target_run_at_ms = 90_000,
		state = "active",
		in_flight = false,
		leased_at_ms = 0,
	}

	// 1. Due and active -> can claim
	testing.expect(t, prompt_scheduler_can_claim(item, now), "active due prompt can be claimed")

	// 2. Not due yet -> cannot claim
	item.target_run_at_ms = 110_000
	testing.expect(t, !prompt_scheduler_can_claim(item, now), "future prompt cannot be claimed")
	item.target_run_at_ms = 90_000

	// 3. Completed -> cannot claim
	item.state = "completed"
	testing.expect(t, !prompt_scheduler_can_claim(item, now), "completed prompt cannot be claimed")
	item.state = "active"

	// 4. In flight within lease window (e.g. 10s into 60s lease) -> cannot claim
	item.in_flight = true
	item.leased_at_ms = now - 10_000
	testing.expect(t, !prompt_scheduler_can_claim(item, now, 60_000), "prompt in-flight within lease window cannot be claimed")

	// 5. In flight with expired lease (e.g. 70s into 60s lease) -> lease recovery allows claim
	item.leased_at_ms = now - 70_000
	testing.expect(t, prompt_scheduler_can_claim(item, now, 60_000), "prompt with expired lease can be claimed")
}

@(test)
test_prompt_scheduler_claim_and_recovery :: proc(t: ^testing.T) {
	now := i64(200_000)
	item := Prompt_Queue_Item{
		id = "sp_2",
		target_instance_id = "inst_1",
		target_run_at_ms = 150_000,
		state = "active",
		in_flight = false,
		leased_at_ms = 0,
	}

	// Claim
	prompt_scheduler_claim(&item, now)
	testing.expect(t, item.in_flight == true, "item must be in_flight after claim")
	testing.expect(t, item.state == "in_flight", "item state must be in_flight after claim")
	testing.expect(t, item.leased_at_ms == now, "item leased_at_ms must be now")

	// Attempt recover before window (30s later) -> should return false and stay in_flight
	recovered_early := prompt_scheduler_recover_lease(&item, now + 30_000, 60_000)
	testing.expect(t, !recovered_early, "should not recover early")
	testing.expect(t, item.in_flight == true, "still in_flight")

	// Attempt recover after window (70s later) -> should return true and reset active
	recovered := prompt_scheduler_recover_lease(&item, now + 70_000, 60_000)
	testing.expect(t, recovered, "should recover expired lease")
	testing.expect(t, item.in_flight == false, "in_flight must be false after recovery")
	testing.expect(t, item.state == "active", "state must be active after recovery")
}

@(test)
test_prompt_scheduler_advance :: proc(t: ^testing.T) {
	target := i64(1_000_000)

	// 1. One-time prompt (interval_seconds = 0) -> completed
	next1, completed1 := prompt_scheduler_advance_ms(target, 0, 1_005_000)
	testing.expect(t, completed1, "one-time prompt must be completed")
	testing.expect(t, next1 == target, "target_run_at unchanged on completion")

	// 2. Normal recurring advance (interval = 60s = 60_000ms)
	// target = 1_000_000, now = 1_000_500 (executed on time)
	next2, completed2 := prompt_scheduler_advance_ms(target, 60, 1_000_500)
	testing.expect(t, !completed2, "recurring prompt must not be completed")
	testing.expect(t, next2 == 1_060_000, "next run must advance by 60s")

	// 3. Missed intervals resync:
	// target = 1_000_000, interval = 60s, bridge was offline and now = 1_150_000 (2.5 intervals later)
	// Missed intervals should fire once and resync to the next future slot:
	// slot 1: 1_060_000 (missed)
	// slot 2: 1_120_000 (missed)
	// slot 3: 1_180_000 (> now 1_150_000) -> next slot!
	next3, completed3 := prompt_scheduler_advance_ms(target, 60, 1_150_000)
	testing.expect(t, !completed3, "recurring prompt must not be completed")
	testing.expect(t, next3 == 1_180_000, "missed intervals must resync to next future slot (1_180_000)")
}
