package taskchain

import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_valid_chain_transitions_with_archived :: proc(t: ^testing.T) {
	// Active transitions
	testing.expect(t, valid_chain_transition(.Active, .Archived), "Active -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Completed), "Active -> Completed must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Cancelled), "Active -> Cancelled must be valid")
	testing.expect(t, valid_chain_transition(.Active, .Active), "Active -> Active must be valid")

	// Completed transitions
	testing.expect(t, valid_chain_transition(.Completed, .Archived), "Completed -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Completed, .Active), "Completed -> Active must be valid")
	testing.expect(t, valid_chain_transition(.Completed, .Completed), "Completed -> Completed must be valid")
	testing.expect(t, !valid_chain_transition(.Completed, .Cancelled), "Completed -> Cancelled must be invalid")

	// Cancelled transitions
	testing.expect(t, valid_chain_transition(.Cancelled, .Archived), "Cancelled -> Archived must be valid")
	testing.expect(t, valid_chain_transition(.Cancelled, .Cancelled), "Cancelled -> Cancelled must be valid")
	testing.expect(t, !valid_chain_transition(.Cancelled, .Active), "Cancelled -> Active must be invalid")
	testing.expect(t, !valid_chain_transition(.Cancelled, .Completed), "Cancelled -> Completed must be invalid")

	// Archived transitions
	testing.expect(t, valid_chain_transition(.Archived, .Active), "Archived -> Active (restore) must be valid")
	testing.expect(t, valid_chain_transition(.Archived, .Archived), "Archived -> Archived must be valid")
	testing.expect(t, !valid_chain_transition(.Archived, .Completed), "Archived -> Completed must be invalid")
	testing.expect(t, !valid_chain_transition(.Archived, .Cancelled), "Archived -> Cancelled must be invalid")
}

@(test)
test_chain_status_from_string_archived :: proc(t: ^testing.T) {
	testing.expect_value(t, chain_status_from_string("archived"), domain.Task_Chain_Status.Archived)
	testing.expect_value(t, chain_status_from_string("active"), domain.Task_Chain_Status.Active)
	testing.expect_value(t, chain_status_from_string("completed"), domain.Task_Chain_Status.Completed)
	testing.expect_value(t, chain_status_from_string("cancelled"), domain.Task_Chain_Status.Cancelled)
	testing.expect_value(t, chain_status_from_string("unknown"), domain.Task_Chain_Status.Active)
}
