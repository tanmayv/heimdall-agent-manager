package provider

import "core:testing"

@(test)
test_provider_test_active_runs_for_bridge_is_owner_scoped_and_ignores_terminal_runs :: proc(
	t: ^testing.T,
) {
	service := new_provider_service(nil)
	defer {
		for &run in service.test_runs do provider_test_run_destroy(&run)
		delete(service.test_runs)
	}

	runs := []Provider_Test_Run {
		{
			run_id = "active_match",
			owner_user_id = "alice",
			bridge_id = "bridge-a",
			state = "detecting",
		},
		{
			run_id = "other_bridge",
			owner_user_id = "alice",
			bridge_id = "bridge-b",
			state = "detecting",
		},
		{
			run_id = "other_owner",
			owner_user_id = "bob",
			bridge_id = "bridge-a",
			state = "detecting",
		},
		{
			run_id = "terminal",
			owner_user_id = "alice",
			bridge_id = "bridge-a",
			state = "cancelled",
		},
	}
	for run in runs {
		append(&service.test_runs, provider_test_run_clone(run))
	}

	matching := provider_test_active_runs_for_bridge(&service, "alice", "bridge-a")
	defer provider_test_runs_destroy(matching)
	testing.expect_value(t, len(matching), 1)
	if len(matching) == 1 do testing.expect_value(t, matching[0].run_id, "active_match")
}
