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
expect_repository_write_survives_rollback :: proc(t: ^testing.T, conn: ^Conn, write: proc(^Conn) -> bool, verify: proc(^Conn) -> bool, owner_write: proc(^Conn) -> bool = nil) {
    factory_impl: SQLite_Unit_Of_Work_Factory
    repos: iface.Repositories
    factory := new_unit_of_work_factory(&factory_impl, conn, &repos)
    uow, opened, _ := iface.unit_of_work_begin(&factory)
    if !testing.expect(t, opened) do return
    if owner_write != nil do testing.expect(t, owner_write(conn), "owner seeded an uncommitted row")
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

@(test)
test_lsp_config_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, db_path, opened := tmpl_clone_migrated_into_file(t, "lsp_config_rollback")
    defer tmpl_remove_db(db_path)
    if !testing.expect(t, opened) do return
    defer close(&conn)
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Lsp_Server_Config_Repo_SQLite{conn=c}
        saved, _ := lsp_server_config_upsert_sqlite(rawptr(&impl), domain.Lsp_Server_Config{
            config_id="lsp_gate", owner_user_id="owner", bridge_id="bridge", language="odin", cmd="ols",
        })
        return saved
    }, proc(c: ^Conn) -> bool {
        impl := Lsp_Server_Config_Repo_SQLite{conn=c}
        cfg, found, err := lsp_server_config_get_sqlite(rawptr(&impl), "owner", "lsp_gate")
        defer domain.lsp_server_config_destroy(cfg)
        return found && err.code == .None && cfg.cmd == "ols"
    })
}

@(test)
test_issue_write_survives_other_thread_rollback :: proc(t: ^testing.T) {
    conn, db_path, opened := tmpl_clone_migrated_into_file(t, "issue_rollback")
    defer tmpl_remove_db(db_path)
    if !testing.expect(t, opened) do return
    defer close(&conn)
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Issue_Repo_SQLite{conn=c}
        _, saved, _ := issue_save_sqlite(rawptr(&impl), domain.Issue{
            issue_id="issue_gate", owner_user_id="owner", title="survives",
        })
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_exists(c, "SELECT 1 FROM issues;")
    })
}

@(test)
test_issue_decision_read_ignores_other_thread_rollback :: proc(t: ^testing.T) {
    conn, db_path, opened := tmpl_clone_migrated_into_file(t, "issue_read_rollback")
    defer tmpl_remove_db(db_path)
    if !testing.expect(t, opened) do return
    defer close(&conn)
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Issue_Repo_SQLite{conn=c}
        _, found, err := issue_get_sqlite(rawptr(&impl), "uncommitted_issue", "owner")
        return !found && err.code == .Not_Found
    }, proc(c: ^Conn) -> bool {
        return !rollback_probe_exists(c, "SELECT 1 FROM issues;")
    }, owner_write=proc(c: ^Conn) -> bool {
        impl := Issue_Repo_SQLite{conn=c}
        _, saved, _ := issue_save_sqlite(rawptr(&impl), domain.Issue{
            issue_id="uncommitted_issue", owner_user_id="owner", title="must disappear",
        })
        return saved
    })
}

expect_migrated_repository_rollback :: proc(t: ^testing.T, tag: string, write: proc(^Conn) -> bool, verify: proc(^Conn) -> bool) {
    conn, db_path, opened := tmpl_clone_migrated_into_file(t, tag)
    defer tmpl_remove_db(db_path)
    if !testing.expect(t, opened) do return
    defer close(&conn)
    expect_repository_write_survives_rollback(t, &conn, write, verify)
}

rollback_probe_key :: proc(c: ^Conn, query, key: string) -> bool {
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(c.db, cstring(raw_data(query)), -1, &stmt, nil) != SQLITE_OK do return false
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, key)
    return sqlite3_step(stmt) == SQLITE_ROW
}

@(test)
test_agent_audit_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "agent_audit_rollback", proc(c: ^Conn) -> bool {
        impl := Agent_Write_Repo_SQLite{conn=c}
        err := agent_write_insert_sqlite(rawptr(&impl), domain.Agent_Write{owner_user_id="owner", resource_kind="project", resource_id="gate", action="create"})
        return err.code == .None
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM agent_writes WHERE resource_id=?;", "gate")
    })
}

@(test)
test_attention_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "attention_rollback", proc(c: ^Conn) -> bool {
        impl := Attention_Repo_SQLite{conn=c}
        saved, _ := attention_card_insert_if_absent_sqlite(rawptr(&impl), domain.Card{card_id="gate", owner_user_id="owner", title="survives"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM cards WHERE card_id=?;", "gate")
    })
}

@(test)
test_card_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "card_rollback", proc(c: ^Conn) -> bool {
        impl := Card_Repo_SQLite{conn=c}
        _, saved, _ := card_create_sqlite(rawptr(&impl), domain.Card{card_id="gate", owner_user_id="owner", title="survives"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM cards WHERE card_id=?;", "gate")
    })
}

@(test)
test_bot_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "bot_rollback", proc(c: ^Conn) -> bool {
        impl := Bot_Repo_SQLite{conn=c}
        err := bot_insert_sqlite(rawptr(&impl), domain.Bot{bot_id="gate", owner_user_id="owner", agent_id="agent", agent_instance_id="instance"})
        return err.code == .None
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM bots WHERE bot_id=?;", "gate")
    })
}

@(test)
test_bridge_log_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "bridge_log_rollback", proc(c: ^Conn) -> bool {
        impl := Bridge_Log_Repo_SQLite{conn=c}
        count, err := bridge_log_insert_batch_sqlite(rawptr(&impl), []domain.Bridge_Log_Event{{bridge_id="gate", level="info", code="probe", count=1}})
        return count == 1 && err.code == .None
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM bridge_log_events WHERE bridge_id=?;", "gate")
    })
}

@(test)
test_content_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "content_rollback", proc(c: ^Conn) -> bool {
        impl := Content_Repo_SQLite{conn=c}
        _, saved, _ := content_save_conversation_sqlite(rawptr(&impl), domain.Chat_Conversation{conversation_id="gate", owner_user_id="owner", title="survives"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM chat_conversations WHERE conversation_id=?;", "gate")
    })
}

@(test)
test_provider_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "provider_rollback", proc(c: ^Conn) -> bool {
        impl := Provider_Repo_SQLite{conn=c}
        saved, _ := bridge_provider_setting_upsert_sqlite(rawptr(&impl), domain.Bridge_Provider_Setting{bridge_id="gate", provider="codex"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM bridge_provider_settings WHERE bridge_id=?;", "gate")
    })
}

@(test)
test_shell_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "shell_rollback", proc(c: ^Conn) -> bool {
        impl := Shell_Session_Repo_SQLite{conn=c}
        saved, _ := shell_session_upsert_sqlite(rawptr(&impl), domain.Shell_Session{session_id="gate", owner_user_id="owner", bridge_id="bridge", kind="run", status="running", cmd="true"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM shell_sessions WHERE session_id=?;", "gate")
    })
}

@(test)
test_taskchain_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "taskchain_rollback", proc(c: ^Conn) -> bool {
        impl := Taskchain_Repo_SQLite{conn=c}
        _, saved, _ := taskchain_save_chain_sqlite(rawptr(&impl), domain.Task_Chain{chain_id="gate", owner_user_id="owner", title="survives", kind=domain.CHAIN_KIND_MIXED_WORK})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM task_chains WHERE chain_id=?;", "gate")
    })
}

@(test)
test_launch_preferences_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "launch_preferences_rollback", proc(c: ^Conn) -> bool {
        impl := User_Repo_SQLite{conn=c}
        _, user_saved, _ := user_save_sqlite(rawptr(&impl), domain.User{user_id="gate", name="gate"})
        if !user_saved do return false
        saved, _ := launch_preferences_save_sqlite(rawptr(&impl), "gate", "{}")
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM user_conversation_launch_preferences WHERE owner_user_id=?;", "gate")
    })
}

@(test)
test_vault_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "vault_rollback", proc(c: ^Conn) -> bool {
        impl := Vault_Directory_Repo_SQLite{conn=c}
        saved, _ := vault_consume_request_nonce_sqlite(rawptr(&impl), "owner", "device", "gate", 100, 200)
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM vault_request_nonces WHERE nonce=?;", "gate")
    })
}

@(test)
test_native_mcp_write_survives_foreign_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "mcp_rollback", proc(c: ^Conn) -> bool {
        err := mcp_put_sqlite(rawptr(c), domain.MCP_Record{kind="grant", id="gate", owner="owner"})
        return err.code == .None
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM mcp_records WHERE id=?;", "gate")
    })
}

@(test)
test_native_mcp_receipt_survives_foreign_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "mcp_receipt_rollback", proc(c: ^Conn) -> bool {
        err := mcp_receipt_put(c, "owner", "grant", "tool", "gate", "digest", "result")
        return err.code == .None
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM mcp_mutation_receipts WHERE request_id=?;", "gate")
    })
}

@(test)
test_agent_decision_read_ignores_foreign_uncommitted_instance :: proc(t: ^testing.T) {
    conn, db_path, opened := tmpl_clone_migrated_into_file(t, "agent_decision_rollback")
    defer tmpl_remove_db(db_path)
    if !testing.expect(t, opened) do return
    defer close(&conn)
    expect_repository_write_survives_rollback(t, &conn, proc(c: ^Conn) -> bool {
        impl := Agent_Repo_SQLite{conn=c}
        row, found, err := agent_get_instance_sqlite(rawptr(&impl), "uncommitted")
        defer domain.agent_instance_destroy(&row)
        return !found && err.code == .Not_Found
    }, proc(c: ^Conn) -> bool {
        return !rollback_probe_key(c, "SELECT 1 FROM agent_instances WHERE agent_instance_id=?;", "uncommitted")
    }, owner_write=proc(c: ^Conn) -> bool {
        impl := Agent_Repo_SQLite{conn=c}
        _, saved, _ := agent_save_instance_sqlite(rawptr(&impl), domain.Agent_Instance{agent_instance_id="uncommitted", owner_user_id="owner"})
        return saved
    })
}

@(test)
test_agent_instance_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "agent_instance_rollback", proc(c: ^Conn) -> bool {
        impl := Agent_Repo_SQLite{conn=c}
        _, saved, _ := agent_save_instance_sqlite(rawptr(&impl), domain.Agent_Instance{agent_instance_id="gate", owner_user_id="owner", runtime_status="running"})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM agent_instances WHERE agent_instance_id=?;", "gate")
    })
}

@(test)
test_bridge_repository_write_survives_rollback :: proc(t: ^testing.T) {
    expect_migrated_repository_rollback(t, "bridge_rollback", proc(c: ^Conn) -> bool {
        impl := Bridge_Repo_SQLite{conn=c}
        _, saved, _ := bridge_save_bridge_sqlite(rawptr(&impl), domain.Bridge{bridge_id="gate", owner_user_id="owner", status=.Online})
        return saved
    }, proc(c: ^Conn) -> bool {
        return rollback_probe_key(c, "SELECT 1 FROM bridges WHERE bridge_id=?;", "gate")
    })
}
