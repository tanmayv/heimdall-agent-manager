package agent
import "core:mem"
import "core:mem/virtual"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

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
