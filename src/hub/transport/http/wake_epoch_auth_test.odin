package http

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import auth "odin_test:hub/service/auth"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
startup_wake_epoch_assertion_authenticates_first_launch :: proc(t: ^testing.T) {
    arena: virtual.Arena
    _ = virtual.arena_init_growing(&arena)
    defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena)
    f := wire_setup(t, "wake_epoch")
    defer wire_teardown(f)
    testing.expect(t, sqlite.exec(&f.conn, "UPDATE agent_instances SET launch_epoch='wake_epoch' WHERE agent_instance_id='inst_wire_tb2';"))
    req := auth.Auth_Request{remote_addr="127.0.0.1", headers=f.agent_headers[:]}
    _, bare_ok, _ := auth.resolve_auth_any(&f.auth_svc, req)
    testing.expect(t, !bare_ok, "bare wake assertion is rejected")
    f.agent_headers[1].value = strings.concatenate({"hit_", f.instance_id, "~wake_epoch"})
    identity, accepted, err := auth.resolve_auth_any(&f.auth_svc, req)
    testing.expect(t, accepted, err.message)
    testing.expect_value(t, identity.agent_instance_id, f.instance_id)
}
