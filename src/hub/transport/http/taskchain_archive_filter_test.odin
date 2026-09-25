package http

import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

@(test)
test_chain_status_http_archived :: proc(t: ^testing.T) {
	testing.expect_value(t, chain_status_http(.Archived), "archived")
	testing.expect_value(t, chain_status_http(.Active), "active")
	testing.expect_value(t, chain_status_http(.Completed), "completed")
	testing.expect_value(t, chain_status_http(.Cancelled), "cancelled")
}

@(test)
test_enrich_chain_list_items_archive_filter :: proc(t: ^testing.T) {
	h: Taskchain_Handlers
	auth: contracts.Auth_Context
	chains := []domain.Task_Chain{
		domain.Task_Chain{chain_id = "chain_1", title = "Active Chain", status = .Active},
		domain.Task_Chain{chain_id = "chain_2", title = "Archived Chain", status = .Archived},
		domain.Task_Chain{chain_id = "chain_3", title = "Completed Chain", status = .Completed},
	}

	// When include_archived is false (default), Archived chains must be excluded
	items_default := enrich_chain_list_items(&h, auth, chains, false, false)
	defer delete(items_default)
	testing.expect_value(t, len(items_default), 2)
	testing.expect_value(t, items_default[0].chain_id, "chain_1")
	testing.expect_value(t, items_default[1].chain_id, "chain_3")

	// When include_archived is true, Archived chains must be included
	items_all := enrich_chain_list_items(&h, auth, chains, false, true)
	defer delete(items_all)
	testing.expect_value(t, len(items_all), 3)
	testing.expect_value(t, items_all[0].chain_id, "chain_1")
	testing.expect_value(t, items_all[1].chain_id, "chain_2")
	testing.expect_value(t, items_all[1].status, "archived")
	testing.expect_value(t, items_all[2].chain_id, "chain_3")
}
