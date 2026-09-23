package main

import "core:testing"
import domain "odin_test:hub/domain"

// make_cfg is a test helper that builds a minimal Lsp_Server_Config.
// It does NOT allocate heap strings — the literals live in the test binary's
// read-only segment, so the tracking allocator never sees them.  Do not call
// lsp_server_config_destroy on values produced here.
@(private)
make_cfg :: proc(language, dir_prefix: string) -> domain.Lsp_Server_Config {
	return domain.Lsp_Server_Config{
		config_id = "id",
		language  = language,
		dir_prefix = dir_prefix,
		cmd       = "lsp",
	}
}

// --- resolution tests ---

// No configs at all — must return false.
@(test)
test_lsp_resolve_no_configs :: proc(t: ^testing.T) {
	_, found := domain.lsp_server_config_resolve(nil, "/work/main.go")
	testing.expect(t, !found, "expected no match with empty config slice")
}

// Only a language default (dir_prefix="") — must match any path.
@(test)
test_lsp_resolve_default_only :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{make_cfg("go", "")}
	got, found := domain.lsp_server_config_resolve(configs, "/work/main.go")
	testing.expect(t, found, "expected default to match")
	testing.expect(t, got.dir_prefix == "", "expected the default row")
}

// One specific override — it must win over the default.
@(test)
test_lsp_resolve_one_override :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/main.go")
	testing.expect(t, found, "expected a match")
	testing.expect(t, got.dir_prefix == "/work/project", "override must beat default")
}

// File outside the override directory — must fall back to default.
@(test)
test_lsp_resolve_fallback_to_default :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/home/user/other.go")
	testing.expect(t, found, "expected default match for path outside override")
	testing.expect(t, got.dir_prefix == "", "expected default row for unrelated path")
}

// Nested overrides — the LONGER prefix must win.
@(test)
test_lsp_resolve_nested_overrides :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work"),
		make_cfg("go", "/work/project"),
		make_cfg("go", "/work/project/pkg"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/pkg/types.go")
	testing.expect(t, found, "expected match for nested overrides")
	testing.expect(t, got.dir_prefix == "/work/project/pkg", "longest prefix must win")
}

// Sibling directory boundary — /work/exp must NOT match /work/experiment/main.go.
@(test)
test_lsp_resolve_sibling_dir_no_match :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "/work/exp"),
	}
	_, found := domain.lsp_server_config_resolve(configs, "/work/experiment/main.go")
	testing.expect(t, !found, "/work/exp must not match /work/experiment/main.go (path boundary)")
}

// Sibling directory — /work/exp MUST match /work/exp/main.go.
@(test)
test_lsp_resolve_exact_prefix_matches :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "/work/exp"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/exp/main.go")
	testing.expect(t, found, "/work/exp must match /work/exp/main.go")
	testing.expect(t, got.dir_prefix == "/work/exp", "expected the /work/exp row")
}

// Exact match (file_path == dir_prefix with no trailing slash) must still match.
@(test)
test_lsp_resolve_exact_path_match :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", "/work/project"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project")
	testing.expect(t, found, "exact path match (no trailing slash) must work")
	testing.expect(t, got.dir_prefix == "/work/project", "expected the row")
}

// Boundary rejection with fallback: /work/exp must NOT match /work/experiment/main.go
// but the language default must still be returned (not "no match").
@(test)
test_lsp_resolve_boundary_fallback_to_default :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/exp"),
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/experiment/main.go")
	testing.expect(t, found, "default must match when override is rejected by path boundary")
	testing.expect(t, got.dir_prefix == "", "expected default row (not the /work/exp override)")
}

// A dir_prefix with a trailing slash (what old/buggy code stores) can NEVER resolve,
// because the path-boundary check reads file_path[len(prefix)] which is already past
// the '/' separator. The create handler must normalize by stripping trailing slashes.
// This test documents that invariant and acts as a regression guard.
@(test)
test_lsp_resolve_trailing_slash_prefix_never_matches :: proc(t: ^testing.T) {
	// Simulate what the old code (without normalization) would store.
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project/"), // single trailing slash — invalid stored value
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/main.go")
	testing.expect(t, found, "default must still match when override has trailing slash")
	testing.expect(t, got.dir_prefix == "", "trailing-slash override must not win (boundary check fails)")
}

// A dir_prefix with MULTIPLE trailing slashes also silently misses — documents that
// the handler must strip ALL trailing slashes (strings.trim_right, not a single chop).
@(test)
test_lsp_resolve_double_trailing_slash_prefix_never_matches :: proc(t: ^testing.T) {
	configs := []domain.Lsp_Server_Config{
		make_cfg("go", ""),
		make_cfg("go", "/work/project//"), // double trailing slash — still invalid
	}
	got, found := domain.lsp_server_config_resolve(configs, "/work/project/main.go")
	testing.expect(t, found, "default must still match when override has double trailing slash")
	testing.expect(t, got.dir_prefix == "", "double-trailing-slash override must not win")
}
