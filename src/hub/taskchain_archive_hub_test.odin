package main

import "core:testing"
import domain "odin_test:hub/domain"
import repo_sqlite "odin_test:hub/repository/sqlite"
import taskchain_service "odin_test:hub/service/taskchain"
import hub_http "odin_test:hub/transport/http"

@(test)
test_task_chain_archived_transitions :: proc(t: ^testing.T) {
	// Active transitions
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Archived), "Active -> Archived must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Completed), "Active -> Completed must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Cancelled), "Active -> Cancelled must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Active, .Active), "Active -> Active must be valid")

	// Completed transitions
	testing.expect(t, taskchain_service.valid_chain_transition(.Completed, .Archived), "Completed -> Archived must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Completed, .Active), "Completed -> Active must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Completed, .Completed), "Completed -> Completed must be valid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Completed, .Cancelled), "Completed -> Cancelled must be invalid")

	// Cancelled transitions
	testing.expect(t, taskchain_service.valid_chain_transition(.Cancelled, .Archived), "Cancelled -> Archived must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Cancelled, .Cancelled), "Cancelled -> Cancelled must be valid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Cancelled, .Active), "Cancelled -> Active must stay invalid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Cancelled, .Completed), "Cancelled -> Completed must be invalid")

	// Archived transitions
	testing.expect(t, taskchain_service.valid_chain_transition(.Archived, .Active), "Archived -> Active (restore) must be valid")
	testing.expect(t, taskchain_service.valid_chain_transition(.Archived, .Archived), "Archived -> Archived must be valid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Archived, .Completed), "Archived -> Completed must be invalid")
	testing.expect(t, !taskchain_service.valid_chain_transition(.Archived, .Cancelled), "Archived -> Cancelled must be invalid")
}

@(test)
test_task_chain_archived_status_mappings :: proc(t: ^testing.T) {
	// Service string mapping
	testing.expect_value(t, taskchain_service.chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)

	// SQLite repo mappings
	testing.expect_value(t, repo_sqlite.chain_status_string(.Archived), "archived")
	testing.expect_value(t, repo_sqlite.chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)

	// HTTP handler mappings
	testing.expect_value(t, hub_http.chain_status_http(.Archived), "archived")
}
