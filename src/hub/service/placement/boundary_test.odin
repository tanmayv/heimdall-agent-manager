package placement

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Boundary_Exception :: struct {
	file, procedure, reason: string,
}
// These checks describe connectivity or stop/fence an existing runtime. They
// must not interpret launch restrictions as evidence a process is disconnected.
BOUNDARY_EXCEPTIONS :: []Boundary_Exception {
	{
		"agent/agent_service.odin",
		"cleanup_provider_test_instance",
		"Stop a provider test only while its transport is connected.",
	},
	{"agent/agent_service.odin", "stop_instance", "A plan-disabled bridge can still contain the process to stop."},
	{
		"agent/instance_reconfiguration.odin",
		"begin_instance_reconfiguration",
		"Fence the source only when its connection is actually absent.",
	},
	{
		"agent/instance_reconfiguration.odin",
		"reconfiguration_start_stop",
		"Failed stop transport is not proof a connected source is stopped.",
	},
	{
		"agent/instance_reconfiguration.odin",
		"force_stop_instance_reconfiguration_locked",
		"Force stop needs connectivity regardless of launch eligibility.",
	},
	{
		"bots/supervisor.odin",
		"bots_resolve_blocking_locked",
		"Existing runtime recovery follows connectivity, not launch restrictions.",
	},
	{"bots/delivery.odin", "bots_on_bridge_disconnect", "Do not mark a newer replacement connection disconnected."},
}
boundary_scan :: proc(t: ^testing.T, dir: string, imports: bool) -> int {
	entries, e := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect(t, e == nil)
	count := 0
	for entry in entries {
		if entry.type == .Directory {count += boundary_scan(t, entry.fullpath, imports); continue}
		if !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") do continue
		data, re := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if !testing.expect(t, re == nil) do continue
		count += 1; procedure := ""
		for raw in strings.split_lines(string(data), context.temp_allocator) {
			line := strings.trim_space(raw)
			if strings.has_prefix(line, "//") do continue
			if imports {
				if !strings.has_prefix(line, "import ") do continue
				allowed := false
				for prefix in ([]string{"core:", "base:", "odin_test:hub/domain", "odin_test:hub/repository/iface", "odin_test:hub/service/provider", "odin_test:hub/service/project", "odin_test:lib/jsonx", "odin_test:contracts"}) do if strings.contains(line, prefix) do allowed = true
				testing.expectf(t, allowed, "forbidden placement import: %s", line)
				continue
			}
			if at := strings.index(line, " :: proc"); at >= 0 do procedure = line[:at]
			forbidden := false
			for pattern in ([]string{"bridge_runtime_registry_has_live(", ".plan_disabled_at", "status != .Online", "status == .Online", "status!=.Online", "status==.Online"}) do if strings.contains(line, pattern) do forbidden = true
			if !forbidden do continue
			exception := false
			for item in BOUNDARY_EXCEPTIONS do if strings.has_suffix(entry.fullpath, item.file) && procedure == item.procedure && item.reason != "" do exception = true
			testing.expectf(t, exception, "inline eligibility in %s:%s: %s", entry.fullpath, procedure, line)
		}
	}
	return count
}
@(test)
test_placement_imports :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	testing.expect(t, boundary_scan(t, #directory, true) > 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}
@(test)
test_agent_and_bots_use_the_predicate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	root := filepath.dir(strings.trim_right(#directory, "/"))
	testing.expect(t, boundary_scan(t, strings.concatenate({root, "/agent"}, context.temp_allocator), false) > 0)
	testing.expect(t, boundary_scan(t, strings.concatenate({root, "/bots"}, context.temp_allocator), false) > 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}
