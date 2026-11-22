package agent
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import placement "odin_test:hub/service/placement"
import project_service "odin_test:hub/service/project"

@(test)
test_prepare_instance_refuses_pending_bridge :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	{
		arena: virtual.Arena
		assert(virtual.arena_init_growing(&arena) == nil)
		context.allocator = virtual.arena_allocator(&arena)

		db, opened, _ := sqlite.open(":memory:")
		if testing.expect(t, opened) {
			migrated, _ := sqlite.run_migrations(&db)
			testing.expect(t, migrated)
			ai: sqlite.Agent_Repo_SQLite; bi: sqlite.Bridge_Repo_SQLite
			agents := sqlite.new_agent_repository(&ai, &db); bridges := sqlite.new_bridge_repository(&bi, &db)
			svc := Agent_Service {
				agents  = &agents,
				bridges = &bridges,
			}
			_, saved, e := iface.agent_save(&agents, {agent_id = "a", owner_user_id = "alice", state = .Active})
			testing.expect(t, saved, e.message)
			for revoked in ([]bool{false, true}) {
				b := domain.Bridge {
					bridge_id                = "b",
					owner_user_id            = "alice",
					status                   = .Online,
					enrollment_pending_until = "later",
				}
				if revoked {b.enrollment_pending_until = ""; b.revoked_at = "now"}
				_, saved, e = iface.bridge_save_bridge(&bridges, b); testing.expect(t, saved, e.message)
				_, _, ok, err := prepare_instance(
					&svc,
					contracts.Auth_Context{kind = .Session, user_id = "alice"},
					{agent_id = "a", bridge_id = "b", provider = "codex", model = "model"},
				)
				testing.expect(t, !ok); testing.expect_value(t, err.code, domain.Error_Code.Conflict)
				rows, _ := iface.agent_list_instances_by_bridge(&agents, "b")
				testing.expect_value(t, len(rows), 0)
			}
			sqlite.close(&db)
		}
		virtual.arena_destroy(&arena)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}


Review_Placement_Fixture :: struct {
	db:        sqlite.Conn,
	ai:        sqlite.Agent_Repo_SQLite,
	bi:        sqlite.Bridge_Repo_SQLite,
	pi:        sqlite.Provider_Repo_SQLite,
	agents:    iface.Agent_Repository,
	bridges:   iface.Bridge_Repository,
	providers: iface.Provider_Repository,
	registry:  project_service.Bridge_Runtime_Registry,
	service:   Agent_Service,
}
review_placement_setup :: proc(t: ^testing.T, f: ^Review_Placement_Fixture) -> bool {
	db, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return false
	f.db = db
	migrated, _ := sqlite.run_migrations(&f.db)
	if !testing.expect(t, migrated) do return false
	f.agents = sqlite.new_agent_repository(&f.ai, &f.db)
	f.bridges = sqlite.new_bridge_repository(&f.bi, &f.db)
	f.providers = sqlite.new_provider_repository(&f.pi, &f.db)
	f.service = {
		agents                  = &f.agents,
		bridges                 = &f.bridges,
		providers               = &f.providers,
		bridge_runtime_registry = &f.registry,
	}
	_, saved, e := iface.agent_save(&f.agents, {agent_id = "a", owner_user_id = "alice", slug = "a", state = .Active})
	if !testing.expect(t, saved, e.message) do return false
	for id in ([]string{"source", "dest"}) {
		b := domain.Bridge {
			bridge_id     = id,
			owner_user_id = "alice",
			status        = .Online,
		}
		if id == "source" do b.capabilities_json = `{"features":["instance_reconfiguration_v1"]}`
		_, saved, e = iface.bridge_save_bridge(&f.bridges, b)
		if !testing.expect(t, saved, e.message) do return false
	}
	_, saved, e = iface.agent_save_instance(
		&f.agents,
		{
			agent_instance_id = "i",
			owner_user_id = "alice",
			agent_id = "a",
			bridge_id = "source",
			provider = "codex",
			model = "m1",
			runtime_status = "stopped",
		},
	)
	if !testing.expect(t, saved, e.message) do return false
	return project_service.bridge_runtime_registry_mark_live(&f.registry, "dest", false, "")
}
review_placement_close :: proc(f: ^Review_Placement_Fixture) {
	project_service.bridge_runtime_registry_destroy(&f.registry)
	sqlite.close(&f.db)
}
review_missing_feature_scenario :: proc(t: ^testing.T) {
	f: Review_Placement_Fixture
	defer review_placement_close(&f)
	if !review_placement_setup(t, &f) do return
	_, accepted, e := begin_instance_reconfiguration(
		&f.service,
		{kind = .Session, user_id = "alice"},
		"i",
		{
			bridge_id = "dest",
			provider = "codex",
			model = "m1",
			idempotency_key = "missing-feature",
			expected_revision = 0,
		},
	)
	testing.expect(t, !accepted)
	testing.expect_value(t, e.code, domain.Error_Code.Conflict)
	testing.expect_value(t, e.message, "update source and destination bridges before applying configuration changes")
	testing.expect_value(t, e.cause, placement.REASON_MISSING_FEATURE)
	valid:bool
 valid, e = reconfiguration_validate_live_destination(
		&f.service,
		{owner_user_id = "alice", agent_instance_id = "i", destination = {bridge_id = "dest"}},
	)
	testing.expect(t, !valid)
	testing.expect_value(t, e.code, domain.Error_Code.Conflict)
	testing.expect_value(t, e.message, "destination bridge must be updated before Apply")
	testing.expect_value(t, e.cause, placement.REASON_MISSING_FEATURE)
}
@(test)
test_move_missing_feature_preserves_messages :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	context.allocator = virtual.arena_allocator(&arena)
	review_missing_feature_scenario(t)
	virtual.arena_destroy(&arena)
	testing.expect_value(t, len(track.allocation_map), 0)
}
@(test)
test_discarded_legacy_validation_does_not_allocate_on_heap :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	tracked := mem.tracking_allocator(&track)
	context.allocator = tracked
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	{
		context.allocator = virtual.arena_allocator(&arena)
		f: Review_Placement_Fixture
		if review_placement_setup(t, &f) {
			_, e := iface.bridge_provider_status_upsert(
				&f.providers,
				{bridge_id = "dest", provider = "codex", state = "present"},
			)
			testing.expect_value(t, e.code, domain.Error_Code.None)
			e = iface.bridge_provider_models_upsert(
				&f.providers,
				{
					bridge_id = "dest",
					provider = "codex",
					has_snapshot = true,
					models_json = `[{"model_id":"m1","resolved_model":"alias","state":"active"}]`,
				},
			)
			testing.expect_value(t, e.code, domain.Error_Code.None)
			{
				// Fixture setup is scratch, but each validation runs directly on the
				// tracking heap. Discarding the legacy result must allocate no heap memory.
				context.allocator = tracked
				for _ in 0 ..< 16 {
					_, valid, err := validate_provider_model_intersection(&f.service, "dest", "codex", "m1")
					testing.expect(t, valid, err.message)
					_, valid, err = validate_provider_model_intersection(&f.service, "dest", "codex", "alias")
					testing.expect(t, valid, err.message)
				}
				borrowed, valid, err := validate_provider_model_intersection(&f.service, "dest", "codex", "alias")
				testing.expect(t, valid, err.message)
				testing.expect_value(t, borrowed.model, "m1")
				// No delete: both legacy result strings are borrowed.
				testing.expect_value(t, len(track.allocation_map), 0)
			}
		}
		review_placement_close(&f)
	}
	virtual.arena_destroy(&arena)
	testing.expect_value(t, len(track.allocation_map), 0)
}

running_agent_message_flags_scenario :: proc(t: ^testing.T) {
	f: Review_Placement_Fixture
	if !review_placement_setup(t, &f) do return
	defer review_placement_close(&f)
	testing.expect(t, project_service.bridge_runtime_registry_mark_live(&f.registry, "source", false, ""))
	_, e := iface.bridge_provider_status_upsert(&f.providers, {bridge_id = "source", provider = "codex", state = "present"})
	testing.expect_value(t, e.code, domain.Error_Code.None)
	e = iface.bridge_provider_models_upsert(&f.providers, {
		bridge_id = "source", provider = "codex", has_snapshot = true,
		models_json = `[{"model_id":"m1","state":"active"}]`,
	})
	testing.expect_value(t, e.code, domain.Error_Code.None)
	inst, found, instance_err := iface.agent_get_instance(&f.agents, "i")
	if !testing.expect(t, found, instance_err.message) do return
	inst.runtime_status = "running"
	saved: bool
	_, saved, e = iface.agent_save_instance(&f.agents, inst)
	testing.expect(t, saved, e.message)
	for flag in ([]string{"enabled", "plan-disabled", "revoked", "pending"}) {
		bridge := domain.Bridge{bridge_id = "source", owner_user_id = "alice", status = .Online}
		switch flag {
		case "plan-disabled": bridge.plan_disabled_at = "now"
		case "revoked": bridge.revoked_at = "now"
		case "pending": bridge.enrollment_pending_until = "later"
		}
		_, saved, e = iface.bridge_save_bridge(&f.bridges, bridge)
		testing.expect(t, saved, e.message)
		// Ordinary bridge updates preserve the billing-owned plan flag.
		testing.expect(t, sqlite.exec(&f.db, "UPDATE bridges SET plan_disabled_at = '' WHERE bridge_id = 'source'"))
		if flag == "plan-disabled" do testing.expect(t, sqlite.exec(&f.db, "UPDATE bridges SET plan_disabled_at = 'now' WHERE bridge_id = 'source'"))
		stored, exists, read_err := iface.bridge_get_bridge(&f.bridges, "source")
		testing.expect(t, exists, read_err.message)
		testing.expect_value(t, stored.plan_disabled_at, bridge.plan_disabled_at)
		testing.expect_value(t, stored.revoked_at, bridge.revoked_at)
		testing.expect_value(t, stored.enrollment_pending_until, bridge.enrollment_pending_until)
		valid, err := validate_instance_message_configuration(&f.service, "alice", "i")
		testing.expectf(t, valid && err.code == .None, "%s: %s", flag, err.message)
	}
	// The exception must still reject a disconnected conversation.
	project_service.bridge_runtime_registry_destroy(&f.registry)
	valid, err := validate_instance_message_configuration(&f.service, "alice", "i")
	testing.expect(t, !valid)
	testing.expect_value(t, err.code, domain.Error_Code.Bridge_Offline)
}


@(test)
test_running_agent_messages_allow_launch_restricted_bridge_flags :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	context.allocator = virtual.arena_allocator(&arena)
	running_agent_message_flags_scenario(t)
	virtual.arena_destroy(&arena)
	testing.expect_value(t, len(track.allocation_map), 0)
}
