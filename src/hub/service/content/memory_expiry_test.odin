package content

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_content_service_memory_default_expiry_24h :: proc(t: ^testing.T) {
	db_path := "/tmp/test_content_service_memory_expiry.db"
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, _ := sqlite.open(db_path)
	testing.expect(t, open_ok, "db open ok")
	defer sqlite.close(&conn)

	mig_ok, _ := sqlite.run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")

	content_impl := sqlite.Content_Repo_SQLite{conn = &conn}
	content_repo := sqlite.new_content_repository(&content_impl, &conn)

	clock := platform.real_clock()
	ids := platform.real_id_generator()

	svc := new_content_service(&content_repo, nil, nil, nil, nil, &clock, &ids)
	auth := contracts.Auth_Context{user_id = "test_user"}

	// 1. Create memory without explicit expires_at -> should default to roughly now + 24h
	now_str := platform.clock_now(&clock)
	now_t, parse_ok := platform.parse_rfc3339_utc(now_str)
	testing.expect(t, parse_ok, "parse current time ok")

	in1 := Memory_Input{
		title = "Test Memory 1",
		body = "Body 1",
		type = .Fact,
		status = "pending",
	}
	mem1, ok1, err1 := create_memory(&svc, auth, in1)
	testing.expect(t, ok1, "create memory 1 ok")
	testing.expect_value(t, err1.code, domain.Error_Code.None)
	testing.expect(t, mem1.expires_at != "", "expires_at should not be empty")

	exp_t, exp_ok := platform.parse_rfc3339_utc(mem1.expires_at)
	testing.expect(t, exp_ok, "parse expires_at ok")
	diff := time.diff(now_t, exp_t)
	hours := time.duration_hours(diff)
	testing.expect(t, hours >= 23.99 && hours <= 24.01, "expires_at should be ~24h in the future")

	// 2. Create memory with explicit expires_at -> should be preserved
	in2 := Memory_Input{
		title = "Test Memory 2",
		body = "Body 2",
		type = .Fact,
		status = "pending",
		expires_at = "2030-01-01T00:00:00Z",
	}
	mem2, ok2, err2 := create_memory(&svc, auth, in2)
	testing.expect(t, ok2, "create memory 2 ok")
	testing.expect_value(t, err2.code, domain.Error_Code.None)
	testing.expect_value(t, mem2.expires_at, "2030-01-01T00:00:00Z")

	// 3. Verify get_memory returns expires_at from DB
	fetched, get_ok, _ := get_memory(&svc, auth, mem1.memory_id)
	testing.expect(t, get_ok, "get_memory ok")
	testing.expect_value(t, fetched.expires_at, mem1.expires_at)
}
