package content

import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

// F1 audit: an auto-approved agent proposal records auto_approved_at, which
// survives a round trip; a pending proposal or a person's memory does not.
@(test)
test_memory_auto_approved_at_is_recorded_and_persisted :: proc(t: ^testing.T) {
	db_path := "/tmp/test_content_service_memory_auto_approve.db"
	os.remove(db_path)
	defer os.remove(db_path)
	conn, open_ok, _ := sqlite.open(db_path)
	if !testing.expect(t, open_ok, "db open ok") do return
	defer sqlite.close(&conn)
	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	svc := new_content_service(&content_repo, nil, nil, nil, nil, &clock, &ids)
	auth := contracts.Auth_Context{user_id = "test_user"}

	auto, ok, err := create_memory(&svc, auth, Memory_Input{title = "a", body = "b", type = .Fact, status = "active", auto_approved = true, proposed_by_instance_id = "inst_1"})
	if !testing.expect(t, ok, err.message) do return
	testing.expect(t, auto.auto_approved_at != "", "auto approval stamped")
	stored, sok, _ := iface.content_get_memory(&content_repo, auto.memory_id)
	testing.expect(t, sok && stored.auto_approved_at == auto.auto_approved_at, "auto_approved_at persisted")

	pending, pok, _ := create_memory(&svc, auth, Memory_Input{title = "p", body = "b", type = .Fact, status = "pending", auto_approved = true})
	testing.expect(t, pok && pending.auto_approved_at == "", "a pending proposal is not marked auto-approved")
}
