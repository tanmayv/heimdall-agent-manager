package main

import "core:strings"
import "core:testing"

@(test)
test_provider_json_helpers :: proc(t: ^testing.T) {
	body := `{"provider":"codex","models":["gpt-5","gpt-5-pro"]}`
	provider := bridge_provider_json_extract_string(body, "provider", "")
	defer delete(provider)
	testing.expect_value(t, provider, "codex")
	models, ok := bridge_provider_json_extract_string_array(body, "models")
	defer if models != nil {
		for model in models do delete(model)
		delete(models)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(models), 2)
	if len(models) == 2 do testing.expect_value(t, models[1], "gpt-5-pro")
}

@(test)
test_provider_shell_join_quotes_arguments :: proc(t: ^testing.T) {
	joined := bridge_shell_join([]string{"/usr/bin/codex", "-m", "gpt-5 pro", "it's ready"})
	defer delete(joined)
	testing.expect(t, strings.contains(joined, "'gpt-5 pro'"))
	testing.expect(t, strings.contains(joined, "'it'\\''s ready'"))
}

@(test)
test_runtime_find_on_path_returns_owned_path :: proc(t: ^testing.T) {
	path := bridge_runtime_find_on_path("sh")
	if !testing.expect(t, path != "", "test shell is discoverable on PATH") do return
	// The resolver contract gives ownership to the caller. In particular, an
	// already-absolute PATH entry must not be freed inside the resolver and then
	// returned as a dangling string.
	delete(path)
}

@(test)
test_provider_removed_from_path_degrades_to_absent :: proc(t: ^testing.T) {
	result := bridge_provider_probe_one(
		"codex",
		"heimdall-provider-binary-that-does-not-exist-18dcd",
	)
	defer bridge_provider_path_destroy(&result)
	testing.expect_value(t, result.provider, "codex")
	testing.expect_value(t, result.state, "absent")
	testing.expect_value(t, result.resolved_path, "")
	// Destruction is part of the regression: an unavailable formerly-cached
	// provider must produce a fully owned absent record, not a dangling PATH
	// string that crashes the Bridge during launch cleanup.
}
