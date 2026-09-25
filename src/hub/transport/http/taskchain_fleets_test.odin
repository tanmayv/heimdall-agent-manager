package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_write_fleet_json :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_abc"),
		agent_id         = "agt_worker",
		capacity         = 4,
		min_warm         = 2,
		idle_ttl_seconds = 600,
		provider         = "claude",
		tier             = "smart",
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"task_chain_id":"chain_fleet_abc"`), "must contain task_chain_id")
	testing.expect(t, strings.contains(out, `"agent_id":"agt_worker"`), "must contain agent_id")
	testing.expect(t, strings.contains(out, `"capacity":4`), "must contain capacity 4")
	testing.expect(t, strings.contains(out, `"active_count":0`), "must contain active_count 0")
	testing.expect(t, strings.contains(out, `"min_warm":2`), "must contain min_warm 2")
	testing.expect(t, strings.contains(out, `"idle_ttl_seconds":600`), "must contain idle_ttl_seconds 600")
	testing.expect(t, strings.contains(out, `"created_at":"2026-09-23T10:00:00Z"`), "must contain created_at")
	testing.expect(t, strings.contains(out, `"updated_at":"2026-09-23T10:05:00Z"`), "must contain updated_at")
	testing.expect(t, strings.contains(out, `"provider":"claude"`), "must contain provider claude")
	testing.expect(t, strings.contains(out, `"tier":"smart"`), "must contain tier smart")
}

// write_fleet_json is shared by the PUT response and the GET list, so this pins
// the payload contract REQ-FLEET-PT-2 relies on for both verbs.
@(test)
test_write_fleet_json_omitted_provider_tier_empty :: proc(t: ^testing.T) {
	fleet := domain.Task_Chain_Fleet{
		task_chain_id    = domain.Task_Chain_ID("chain_fleet_empty"),
		agent_id         = "agt_worker",
		capacity         = 1,
		min_warm         = 0,
		idle_ttl_seconds = 600,
		created_at       = "2026-09-23T10:00:00Z",
		updated_at       = "2026-09-23T10:05:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_fleet_json(&b, fleet)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, `"provider":""`), "omitted provider must serialize as empty string (inherit)")
	testing.expect(t, strings.contains(out, `"tier":""`), "omitted tier must serialize as empty string (inherit)")
}

@(test)
test_fleet_provider_tier_parse :: proc(t: ^testing.T) {
	body := `{"capacity":2,"provider":"claude","tier":"smart"}`
	testing.expect_value(t, json_string(body, "provider"), "claude")
	testing.expect_value(t, json_string(body, "tier"), "smart")

	spaced := `{"provider": "claude", "tier": "smart"}`
	testing.expect_value(t, json_string(spaced, "provider"), "claude")
	testing.expect_value(t, json_string(spaced, "tier"), "smart")

	omitted := `{"capacity":2}`
	testing.expect_value(t, json_string(omitted, "provider"), "")
	testing.expect_value(t, json_string(omitted, "tier"), "")
}

@(test)
test_json_int_field :: proc(t: ^testing.T) {
	body1 := `{"capacity": 3, "min_warm": 1}`
	testing.expect_value(t, json_int_field(body1, "capacity", 1), 3)
	testing.expect_value(t, json_int_field(body1, "min_warm", 0), 1)
	testing.expect_value(t, json_int_field(body1, "idle_ttl_seconds", 600), 600)

	body2 := `{"capacity": "5", "min_warm": "2", "idle_ttl_seconds": "900"}`
	testing.expect_value(t, json_int_field(body2, "capacity", 1), 5)
	testing.expect_value(t, json_int_field(body2, "min_warm", 0), 2)
	testing.expect_value(t, json_int_field(body2, "idle_ttl_seconds", 600), 900)
}
