package sqlite
import "core:testing"
import "core:os"
import "core:fmt"
import "core:time"
import domain "odin_test:hub/domain"

@(test)
agent_save_busy_is_retriable_but_generation_mismatch_is_conflict :: proc(t: ^testing.T) {
    path := fmt.tprintf("%s/agent-cas-%d.db", os.temp_dir(context.temp_allocator), time.to_unix_nanoseconds(time.now()))
    conn, ok, _ := open(path)
    if !testing.expect(t, ok) do return
    defer { close(&conn); _ = os.remove(path) }
    migrated, _ := run_migrations(&conn)
    if !testing.expect(t, migrated) do return
    testing.expect(t, exec(&conn, "PRAGMA foreign_keys=OFF;"))
    writer, writer_ok, _ := open(path)
    if !testing.expect(t, writer_ok) do return
    defer close(&writer)
    testing.expect(t, exec(&writer, "BEGIN IMMEDIATE;"))
    impl: Agent_Repo_SQLite
    repo := new_agent_repository(&impl, &conn)
    instance := domain.Agent_Instance{agent_instance_id="i",agent_id="a",owner_user_id="u",bridge_id="b"}
    _, saved, err := repo.save_instance(repo.ctx, instance)
    testing.expect(t, !saved)
    testing.expect_value(t, err.code, domain.Error_Code.Bridge_Busy)
    testing.expect(t, exec(&writer, "ROLLBACK;"))
    persisted, saved2, err2 := repo.save_instance(repo.ctx, instance)
    if !testing.expect(t, saved2 && err2.code == .None) do return
    persisted.run_count = -1
    _, saved3, err3 := repo.save_instance(repo.ctx, persisted)
    testing.expect(t, !saved3)
    testing.expect_value(t, err3.code, domain.Error_Code.Conflict)
}
