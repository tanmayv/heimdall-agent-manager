package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"

@(test)
test_experiment_count_enabled :: proc(t: ^testing.T) {
	conn, opened, _ := sqlite.open(":memory:")
	if !testing.expect(t, opened) do return
	defer sqlite.close(&conn)
	testing.expect(
		t,
		sqlite.exec(
			&conn,
			"CREATE TABLE experiments (owner_user_id TEXT, key TEXT, enabled INTEGER, updated_at TEXT, PRIMARY KEY(owner_user_id,key));",
		),
	)
	impl: sqlite.Experiment_Repo_SQLite
	repo := sqlite.new_experiment_repository(&impl, &conn)
	count, err := iface.experiment_count_enabled(&repo, "bots")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, count, 0)
	for owner in ([]string{"alice", "bob", "carol"}) {
		_, set_err := iface.experiment_set(
			&repo,
			{owner_user_id = owner, key = "bots", enabled = owner != "carol", updated_at = "now"},
		)
		testing.expect_value(t, set_err.code, domain.Error_Code.None)
	}
	_, set_err := iface.experiment_set(
		&repo,
		{owner_user_id = "dave", key = "actions", enabled = true, updated_at = "now"},
	)
	testing.expect_value(t, set_err.code, domain.Error_Code.None)
	count, err = iface.experiment_count_enabled(&repo, "bots")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, count, 2)
	_, set_err = iface.experiment_set(
		&repo,
		{owner_user_id = "alice", key = "bots", enabled = false, updated_at = "later"},
	)
	testing.expect_value(t, set_err.code, domain.Error_Code.None)
	count, err = iface.experiment_count_enabled(&repo, "bots")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, count, 1)
	_, missing_err := iface.experiment_count_enabled(nil, "bots")
	testing.expect_value(t, missing_err.code, domain.Error_Code.Internal_Error)
}

Bots_Callback_Test :: struct {
	calls:                           int,
	owner, key:                      string,
	enabled, stored_before_callback: bool,
	repo:                            ^iface.Experiment_Repository,
}
bots_callback_test :: proc(ctx: rawptr, owner, key: string, enabled: bool) {
	state := (^Bots_Callback_Test)(ctx)
	state.calls += 1
	state.owner = owner
	state.key = key
	state.enabled = enabled
	rows, err := iface.experiment_list_by_owner(state.repo, owner)
	defer {
		for row in rows {delete(row.owner_user_id); delete(row.key); delete(row.updated_at)}
		delete(rows)
	}
	if err.code == .None {
		for row in rows do if row.key == key && row.enabled == enabled do state.stored_before_callback = true
	}
}

@(test)
test_experiment_set_calls_on_changed :: proc(t: ^testing.T) {
	f := wire_setup(t, "bots_exp_callback")
	defer wire_teardown(f)
	context.allocator = context.temp_allocator // handlers allocate within a request arena
	impl: sqlite.Experiment_Repo_SQLite
	repo := sqlite.new_experiment_repository(&impl, &f.conn)
	callback := Bots_Callback_Test {
		repo = &repo,
	}
	h := Experiment_Rest_Handlers {
		auth           = &f.auth_svc,
		repo           = &repo,
		clock          = &f.clock,
		on_changed     = bots_callback_test,
		on_changed_ctx = rawptr(&callback),
	}
	before := experiment_list_handler(rawptr(&h), wire_cookie_request(f, "GET", "/api/v1/me/experiments", ""))
	testing.expect_value(t, before.status, 200)
	testing.expect(t, !strings.contains(before.body, `"key":"bots"`))
	response := experiment_set_handler(
		rawptr(&h),
		wire_cookie_request(f, "PUT", "/api/v1/me/experiments/bots", `{"enabled":true}`),
	)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, callback.calls, 1)
	testing.expect_value(t, callback.owner, string(f.owner))
	testing.expect_value(t, callback.key, "bots")
	testing.expect(t, callback.enabled)
	testing.expect(t, callback.stored_before_callback)
	after := experiment_list_handler(rawptr(&h), wire_cookie_request(f, "GET", "/api/v1/me/experiments", ""))
	testing.expect_value(t, after.status, 200)
	testing.expect(t, strings.contains(after.body, `"key":"bots","enabled":true`))
	invalid := experiment_set_handler(
		rawptr(&h),
		wire_cookie_request(f, "PUT", "/api/v1/me/experiments/bots", `{"enabled":"bad"}`),
	)
	testing.expect(t, invalid.status != 200)
	testing.expect_value(t, callback.calls, 1)
	response = experiment_set_handler(
		rawptr(&h),
		wire_cookie_request(f, "PUT", "/api/v1/me/experiments/bots", `{"enabled":false}`),
	)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, callback.calls, 2)
	testing.expect(t, !callback.enabled)
	// A failed store must not notify subscribers.
	h.repo = nil
	response = experiment_set_handler(
		rawptr(&h),
		wire_cookie_request(f, "PUT", "/api/v1/me/experiments/bots", `{"enabled":true}`),
	)
	testing.expect(t, response.status != 200)
	testing.expect_value(t, callback.calls, 2)
}
