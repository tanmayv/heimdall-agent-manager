package http
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import placement "odin_test:hub/service/placement"
import project_service "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"

placement_endpoint_scenario :: proc(t: ^testing.T, feature: bool) {
	f := wire_setup(t, "placement"); defer wire_teardown(f)
	pi: sqlite.Provider_Repo_SQLite
	pr := sqlite.new_provider_repository(&pi, &f.conn)
	providers := provider_service.new_provider_service(&pr)
	registry: project_service.Bridge_Runtime_Registry
	defer project_service.bridge_runtime_registry_destroy(&registry)
	// Enrollment fixtures are pending until completion; explicitly make these
	// launch-ready rows, with just the alternate bridge remaining offline.
	for id in ([]string{f.bridge_pin, f.bridge_alt, f.bridge_foreign}) {
		bridge, found, e := iface.bridge_get_bridge(&f.br_repo, id)
		testing.expect(t, found, e.message)
		bridge.status = .Online; bridge.revoked_at = ""; bridge.enrollment_pending_until = ""; bridge.plan_disabled_at = ""; bridge.capabilities_json = "{}"
		if id == f.bridge_alt do bridge.status = .Offline
		_, saved, save_err := iface.bridge_save_bridge(&f.br_repo, bridge)
		testing.expect(t, saved, save_err.message)
		assert(project_service.bridge_runtime_registry_mark_live(&registry, id, false, ""))
		_, e = iface.bridge_provider_status_upsert(&pr, {bridge_id = id, provider = "codex", state = "present"})
		testing.expect_value(t, e.code, domain.Error_Code.None)
	}
	pin, pin_ok, pin_err := iface.bridge_get_bridge(&f.br_repo, f.bridge_pin)
	testing.expect(t, pin_ok, pin_err.message)
	testing.expectf(t, pin.status == .Online, "pin status %v id %s alt %s", pin.status, f.bridge_pin, f.bridge_alt)
	ps := placement.Service {
		bridges   = &f.br_repo,
		agents    = &f.ag_repo,
		providers = &providers,
		registry  = &registry,
	}
	h := Placement_Handlers {
		auth      = &f.auth_svc,
		placement = &ps,
	}
	query := ""
	if feature do query = "feature=x&feature=y"
	response := placement_candidates_handler(
		&h,
		{method = "GET", path = "/api/v1/placement/candidates", headers = f.user_headers, query = query},
	)
	defer delete(response.body)
	testing.expect_value(t, response.status, 200)
	body: struct {
		data: struct {
			candidates: []Placement_Candidate_Wire,
			bridges:    []Placement_Bridge_Wire,
			providers:  []Placement_Provider_Wire,
		},
	}
	testing.expect(t, json.unmarshal(transmute([]u8)response.body, &body, allocator = context.temp_allocator) == nil)
	testing.expect_value(t, len(body.data.bridges), 2)
	for b in body.data.bridges {
		testing.expect(t, b.bridge_id != f.bridge_foreign)
		if b.bridge_id == f.bridge_alt {testing.expect(t, !b.eligible); testing.expect_value(t, b.reason, "offline")}
		if b.bridge_id ==
		   f.bridge_pin {testing.expect_value(t, b.eligible, !feature); testing.expect_value(t, b.reason, "missing_feature" if feature else "")}
	}
	all := placement.candidates(&ps, {owner = string(f.owner)}, context.temp_allocator)
	ordered := placement.match(nil, all, context.temp_allocator)
	if feature {
		testing.expect_value(t, len(body.data.candidates), 0)
		// Without the filter the same bridge is eligible and has candidates.
		plain := placement_candidates_handler(&h, {method = "GET", headers = f.user_headers})
		defer delete(plain.body)
		testing.expect(t, strings.contains(plain.body, f.bridge_pin))
	} else {
		testing.expect(t, len(ordered) > 1, "endpoint retains every model")
		testing.expect_value(t, len(body.data.candidates), len(ordered))
		for c, i in body.data.candidates {
			testing.expect_value(t, c.rank, i)
			if i <
			   len(
				   ordered,
			   ) {testing.expect_value(t, c.bridge_id, ordered[i].bridge_id); testing.expect_value(t, c.model, ordered[i].model); testing.expect_value(t, c.provider, ordered[i].provider)}
		}
	}
	testing.expect(t, len(body.data.providers) > 0)
}
placement_endpoint_tracked :: proc(t: ^testing.T, feature: bool) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	context.allocator = virtual.arena_allocator(&arena)
	placement_endpoint_scenario(t, feature)
	virtual.arena_destroy(&arena)
	testing.expect_value(t, len(track.allocation_map), 0)
}
@(test)
test_placement_candidates_endpoint :: proc(t: ^testing.T) {placement_endpoint_tracked(t, false)}
@(test)
test_placement_candidates_feature_filter :: proc(t: ^testing.T) {placement_endpoint_tracked(t, true)}
