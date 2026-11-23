package sqlite

import "core:mem/virtual"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Repository_Rollback_Job :: struct {
    conn: ^Conn,
    write: proc(^Conn) -> bool,
    started, done, saved: bool,
}

// The owner opens a real UoW on the shared handle. A second thread must wait
// for rollback before its repository operation can write. Verify the persisted
// row after join as well: merely observing a successful write misses the bug.
expect_repository_write_survives_rollback :: proc(t: ^testing.T, conn: ^Conn, write: proc(^Conn) -> bool, verify: proc(^Conn) -> bool) {
    factory_impl: SQLite_Unit_Of_Work_Factory
    repos: iface.Repositories
    factory := new_unit_of_work_factory(&factory_impl, conn, &repos)
    uow, opened, _ := iface.unit_of_work_begin(&factory)
    if !testing.expect(t, opened) do return
    job := Repository_Rollback_Job{conn=conn, write=write}
    worker := thread.create_and_start_with_data(&job, proc(data: rawptr) {
        arena: virtual.Arena
        _ = virtual.arena_init_growing(&arena)
        defer virtual.arena_destroy(&arena)
        context.allocator = virtual.arena_allocator(&arena)
        j := (^Repository_Rollback_Job)(data)
        sync.atomic_store(&j.started, true)
        j.saved = j.write(j.conn)
        sync.atomic_store(&j.done, true)
    })
    for !sync.atomic_load(&job.started) do time.sleep(time.Millisecond)
    time.sleep(30*time.Millisecond)
    testing.expect(t, !sync.atomic_load(&job.done), "repository write must wait for the owning UoW")
    iface.unit_of_work_rollback(&uow)
    thread.join(worker)
    thread.destroy(worker)
    testing.expect(t, job.saved, "repository write succeeded after rollback")
    testing.expect(t, verify(conn), "other thread persisted its row outside the rolled-back UoW")
}

@(test)
test_project_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    testing.expect(t, exec(&conn, "CREATE TABLE projects(project_id TEXT PRIMARY KEY, owner_user_id TEXT, name TEXT, slug TEXT, description TEXT, repo_url TEXT, vcs_kind TEXT, default_path TEXT, state TEXT, created_at TEXT, updated_at TEXT);"))
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl: Project_Repo_SQLite
        repo := new_project_repository(&impl, c)
        _, saved, _ := project_save_sqlite(repo.ctx, domain.Project{project_id="project_gate", owner_user_id="owner", name="survives"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM projects WHERE project_id='project_gate' AND name='survives';")
    })
}

rollback_probe_exists :: proc(c: ^Conn, query: string) -> bool {
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(c.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false
    defer sqlite3_finalize(stmt)
    return sqlite3_step(stmt) == SQLITE_ROW
}

@(test)
test_user_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    testing.expect(t, exec(&conn, "CREATE TABLE users(user_id TEXT PRIMARY KEY, name TEXT, display_name TEXT, email TEXT, status TEXT, created_at TEXT, updated_at TEXT);"))
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := User_Repo_SQLite{conn=c}
        _, saved, _ := user_save_sqlite(rawptr(&impl), domain.User{user_id="user_gate", name="survives"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM users WHERE user_id='user_gate' AND name='survives';")
    })
}

@(test)
test_experiment_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    testing.expect(t, exec(&conn, "CREATE TABLE experiments(owner_user_id TEXT, key TEXT, enabled INTEGER, updated_at TEXT, PRIMARY KEY(owner_user_id,key));"))
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Experiment_Repo_SQLite{conn=c}
        saved, _ := experiment_set_sqlite(rawptr(&impl), domain.Experiment{owner_user_id="owner", key="gate", enabled=true})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM experiments WHERE owner_user_id='owner' AND key='gate' AND enabled=1;")
    })
}

@(test)
test_session_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    testing.expect(t, exec(&conn, "CREATE TABLE user_sessions(session_id_hash TEXT PRIMARY KEY, user_id TEXT, created_at_ms INTEGER, last_seen_at_ms INTEGER, expires_at_ms INTEGER, idle_expires_at_ms INTEGER, id_token TEXT, user_agent TEXT);"))
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Session_Repo_SQLite{conn=c}
        err := session_create_sqlite(rawptr(&impl), iface.User_Session{session_id_hash="session_gate", user_id="owner", expires_at_ms=1000})
        return err.code == .None
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM user_sessions WHERE session_id_hash='session_gate' AND expires_at_ms=1000;")
    })
}

@(test)
test_push_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    testing.expect(t, exec(&conn, "CREATE TABLE push_subscriptions(id TEXT PRIMARY KEY, owner_user_id TEXT, endpoint TEXT UNIQUE, p256dh TEXT, auth TEXT, created_at TEXT, updated_at TEXT);"))
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Push_Repo_SQLite{conn=c}
        _, saved, _ := push_upsert_by_endpoint_sqlite(rawptr(&impl), domain.Push_Subscription{id="push_gate", owner_user_id="owner", endpoint="endpoint", auth="survives"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM push_subscriptions WHERE id='push_gate' AND auth='survives';")
    })
}

// Nested repository calls retain the outer guard, even after the inner leaves.
@(test)
test_repository_gate_nested_writer_retains_outer_guard :: proc(t: ^testing.T) {
    outer := tx_repository_enter()
    inner := tx_repository_enter()
    testing.expect(t, !tx_mutex_try_lock())
    tx_repository_leave(inner)
    testing.expect(t, !tx_mutex_try_lock())
    tx_repository_leave(outer)
    testing.expect(t, tx_mutex_try_lock())
}

@(test)
test_identity_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    testing.expect(t, exec(&conn, "CREATE TABLE users(user_id TEXT PRIMARY KEY, name TEXT, display_name TEXT, email TEXT, status TEXT, created_at TEXT, updated_at TEXT); CREATE TABLE user_external_identities(issuer TEXT, subject TEXT, user_id TEXT UNIQUE, created_at TEXT, PRIMARY KEY(issuer,subject));"))
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := User_Repo_SQLite{conn=c}
        _, saved, _ := user_resolve_external_sqlite(rawptr(&impl), "issuer", "subject", "identity_gate", "Identity", "", "now", true, false)
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM user_external_identities i JOIN users u ON u.user_id=i.user_id WHERE i.issuer='issuer' AND i.subject='subject' AND u.user_id='identity_gate';")
    })
}
