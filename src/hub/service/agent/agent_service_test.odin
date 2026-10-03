package agent

import "core:mem"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_parse_bridge_capabilities_envelope :: proc(t: ^testing.T) {
	json_str := `{"capabilities":[{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"}]}`
	caps := parse_bridge_capabilities(json_str)
	testing.expect_value(t, len(caps), 1)
	if len(caps) > 0 {
		testing.expect_value(t, caps[0].provider, "claude")
		testing.expect_value(t, len(caps[0].tiers), 2)
		if len(caps[0].tiers) >= 2 {
			testing.expect_value(t, caps[0].tiers[0], "normal")
			testing.expect_value(t, caps[0].tiers[1], "smart")
		}
		testing.expect_value(t, caps[0].default_tier, "normal")
	}
}

@(test)
test_parse_bridge_capabilities_array :: proc(t: ^testing.T) {
	json_str := `[{"provider":"gemini","tiers":["fast"],"default_tier":"fast"}]`
	caps := parse_bridge_capabilities(json_str)
	testing.expect_value(t, len(caps), 1)
	if len(caps) > 0 {
		testing.expect_value(t, caps[0].provider, "gemini")
		testing.expect_value(t, len(caps[0].tiers), 1)
		if len(caps[0].tiers) >= 1 {
			testing.expect_value(t, caps[0].tiers[0], "fast")
		}
		testing.expect_value(t, caps[0].default_tier, "fast")
	}
}

@(test)
test_parse_bridge_capabilities_key_order_independence :: proc(t: ^testing.T) {
	// "tiers" before "provider", "default_tier" before "tiers", etc.
	json_str := `[{"tiers":["fast","smart"],"provider":"gemini","default_tier":"fast"},{"default_tier":"normal","provider":"claude","tiers":["normal"]}]`
	caps := parse_bridge_capabilities(json_str)
	testing.expect_value(t, len(caps), 2)
	if len(caps) >= 2 {
		testing.expect_value(t, caps[0].provider, "gemini")
		testing.expect_value(t, len(caps[0].tiers), 2)
		testing.expect_value(t, caps[0].default_tier, "fast")

		testing.expect_value(t, caps[1].provider, "claude")
		testing.expect_value(t, len(caps[1].tiers), 1)
		testing.expect_value(t, caps[1].default_tier, "normal")
	}
}

@(test)
test_parse_bridge_capabilities_whitespace_and_newlines :: proc(t: ^testing.T) {
	json_str := "  \n\t {\n\t\"capabilities\":\n\t[\n\t{\n\t\t\"provider\":\t \"claude\" ,\n\t\t\"tiers\": [ \"normal\" , \n\t \"smart\" ],\n\t\t\"default_tier\": \"normal\"\n\t}\n\t]\n}  \n"
	caps := parse_bridge_capabilities(json_str)
	testing.expect_value(t, len(caps), 1)
	if len(caps) > 0 {
		testing.expect_value(t, caps[0].provider, "claude")
		testing.expect_value(t, len(caps[0].tiers), 2)
	}
}

@(test)
test_bridge_capability_matching_procs :: proc(t: ^testing.T) {
	b := domain.Bridge{
		capabilities_json = `{"capabilities":[
			{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"},
			{"provider":"gemini","tiers":["fast"],"default_tier":"fast"}
		]}`,
	}

	// bridge_supports_provider
	testing.expect(t, bridge_supports_provider(b, "claude"))
	testing.expect(t, bridge_supports_provider(b, "gemini"))
	testing.expect(t, !bridge_supports_provider(b, "openai"))
	testing.expect(t, !bridge_supports_provider(b, ""))

	// bridge_supports_provider_tier
	testing.expect(t, bridge_supports_provider_tier(b, "claude", "normal"))
	testing.expect(t, bridge_supports_provider_tier(b, "claude", "smart"))
	testing.expect(t, !bridge_supports_provider_tier(b, "claude", "fast"))
	testing.expect(t, bridge_supports_provider_tier(b, "gemini", "fast"))
	testing.expect(t, !bridge_supports_provider_tier(b, "gemini", "smart"))
	testing.expect(t, !bridge_supports_provider_tier(b, "openai", "fast"))
	testing.expect(t, !bridge_supports_provider_tier(b, "", "normal"))

	// bridge_supports_any_provider_tier
	testing.expect(t, bridge_supports_any_provider_tier(b, "normal"))
	testing.expect(t, bridge_supports_any_provider_tier(b, "smart"))
	testing.expect(t, bridge_supports_any_provider_tier(b, "fast"))
	testing.expect(t, !bridge_supports_any_provider_tier(b, "ultra"))
	testing.expect(t, !bridge_supports_any_provider_tier(b, ""))

	// default_provider_from_bridge
	testing.expect_value(t, default_provider_from_bridge(b), "claude")

	// default_tier_for_provider_from_bridge
	testing.expect_value(t, default_tier_for_provider_from_bridge(b, "claude"), "normal")
	testing.expect_value(t, default_tier_for_provider_from_bridge(b, "gemini"), "fast")
	testing.expect_value(t, default_tier_for_provider_from_bridge(b, "unknown"), "normal")
	testing.expect_value(t, default_tier_for_provider_from_bridge(b, ""), "normal")
}

@(test)
test_bridge_capability_empty_and_invalid :: proc(t: ^testing.T) {
	b_empty := domain.Bridge{capabilities_json = ""}
	testing.expect(t, !bridge_supports_provider(b_empty, "claude"))
	testing.expect(t, !bridge_supports_provider_tier(b_empty, "claude", "normal"))
	testing.expect(t, !bridge_supports_any_provider_tier(b_empty, "normal"))
	testing.expect_value(t, default_provider_from_bridge(b_empty), "")
	testing.expect_value(t, default_tier_for_provider_from_bridge(b_empty, "claude"), "")

	b_invalid := domain.Bridge{capabilities_json = "{not a valid json"}
	testing.expect(t, !bridge_supports_provider(b_invalid, "claude"))
	testing.expect(t, !bridge_supports_provider_tier(b_invalid, "claude", "normal"))
	testing.expect(t, !bridge_supports_any_provider_tier(b_invalid, "normal"))
	testing.expect_value(t, default_provider_from_bridge(b_invalid), "")
}

@(test)
test_bridge_capability_tracking_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	b := domain.Bridge{
		capabilities_json = `{"capabilities":[{"provider":"claude","tiers":["normal","smart"],"default_tier":"normal"}]}`,
	}

	for _ in 0..<10 {
		_ = parse_bridge_capabilities(b.capabilities_json)
		_ = bridge_supports_provider(b, "claude")
		_ = bridge_supports_provider_tier(b, "claude", "smart")
		_ = bridge_supports_any_provider_tier(b, "normal")
		_ = default_provider_from_bridge(b)
		_ = default_tier_for_provider_from_bridge(b, "claude")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
