package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
t4_acp_install_migration_preserves_commands_and_profile_indexes :: proc(t: ^testing.T) {
    conn, opened, _ := open(":memory:")
    if !testing.expect(t, opened) do return
    defer close(&conn)
    migrated, err := run_migrations(&conn, stop_before = "212_acp_adapter_install.sql")
    if !testing.expect(t, migrated, err.message) do return
    testing.expect(t, exec(&conn, "INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('t4','owner','','');"))
    impl: Provider_Repo_SQLite
    repo := new_provider_repository(&impl, &conn)
    created, cerr := iface.provider_extension_command_create(&repo, {command_id = "cmd_old", bridge_id = "t4", kind = "install", provider = "claude", profile_id = "work", state = "dispatched", target_version = "old"})
    testing.expect(t, created, cerr.message)
    migrated, err = run_migrations(&conn)
    if !testing.expect(t, migrated, err.message) do return
    created, cerr = iface.provider_extension_command_create(&repo, {command_id = "cmd_acp", bridge_id = "t4", kind = "install_acp_adapter", provider = "claude", profile_id = "claude", state = "dispatched", target_version = "0.108.0"})
    testing.expect(t, created, cerr.message)
    commands, list_err := iface.provider_extension_command_list(&repo, "t4")
    defer domain.provider_extension_commands_destroy(commands)
    testing.expect_value(t, list_err.code, domain.Error_Code.None)
    testing.expect_value(t, len(commands), 2)
    for c in commands do if c.command_id == "cmd_old" do testing.expect(t, c.profile_id == "work" && c.target_version == "old" && c.state == "dispatched")
    testing.expect(t, !exec(&conn, "INSERT INTO provider_extension_commands(command_id,bridge_id,kind,state) VALUES('bad','t4','arbitrary_command','queued');"))
}
