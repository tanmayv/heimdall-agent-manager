package bots

import "core:os"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Bots_Gate_Test_Repo :: struct {
	enabled, present, failing: bool,
	owner:                     string,
}
bots_gate_test_list :: proc(ctx: rawptr, owner: string) -> ([dynamic]domain.Experiment, domain.Domain_Error) {
	r := (^Bots_Gate_Test_Repo)(ctx)
	if r.failing do return nil, domain.domain_error(.Internal_Error, "test failure")
	rows := make([dynamic]domain.Experiment)
	if r.present && owner == r.owner do append(&rows, domain.Experiment{owner_user_id = strings.clone(owner), key = strings.clone("bots"), enabled = r.enabled})
	return rows, {}
}

@(test)
test_bots_gate_error_off_on_empty_owner_and_repo_failure :: proc(t: ^testing.T) {
	fake := Bots_Gate_Test_Repo {
		owner = "alice",
	}
	repo := iface.Experiment_Repository {
		ctx           = rawptr(&fake),
		list_by_owner = bots_gate_test_list,
	}
	testing.expect_value(t, bots_gate_error(&repo, "alice").code, domain.Error_Code.Forbidden)
	fake.present = true
	testing.expect(t, !bots_gate_on(&repo, "alice"))
	fake.enabled = true
	testing.expect(t, bots_gate_on(&repo, "alice"))
	testing.expect(t, !bots_gate_on(&repo, "bob"))
	testing.expect(t, !bots_gate_on(&repo, ""))
	fake.failing = true
	testing.expect_value(t, bots_gate_error(&repo, "alice").code, domain.Error_Code.Internal_Error)
	testing.expect_value(t, bots_gate_error(nil, "alice").code, domain.Error_Code.Internal_Error)
}

@(test)
test_bots_package_does_not_import_transport :: proc(t: ^testing.T) {
	entries, err := os.read_all_directory_by_path(#directory, context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	count := 0
	forbidden := strings.concatenate({"hub/", "transport"}, context.temp_allocator)
	for e in entries {
		if !strings.has_suffix(e.name, ".odin") do continue
		data, read_err := os.read_entire_file(e.fullpath, context.temp_allocator)
		if !testing.expect(t, read_err == nil) do continue
		testing.expect(t, !strings.contains(string(data), forbidden))
		count += 1
	}
	testing.expect(t, count >= 3)
}

@(test)
test_bot_timer_config_json_preserves_defaults_and_refuses_unknown :: proc(t: ^testing.T) {
	cfg := default_bot_timer_config()
	testing.expect_value(t, cfg.bot_channel_retention_ms, i64(2592000000))
	testing.expect(t, apply_bot_timers_json(&cfg, `{"read_ms":12,"bot_max_rounds":2}`))
	testing.expect_value(t, cfg.read_ms, i64(12))
	testing.expect_value(t, cfg.bot_max_rounds, 2)
	testing.expect_value(t, cfg.bot_attempt_accept_ms, i64(15000))
	before := cfg
	for raw in ([]string {
			`{"unknown":1}`,
			`{"read_ms":"x"}`,
			`{"read_ms":1.2}`,
			`null`,
			`[]`,
			`{"read_ms":1,"unknown":3}`,
		}) {
		testing.expect(t, !apply_bot_timers_json(&cfg, raw))
		testing.expect_value(t, cfg, before)
	}
}
