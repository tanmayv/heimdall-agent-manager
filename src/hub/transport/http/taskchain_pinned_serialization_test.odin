package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_write_chain_list_item_json_pinned :: proc(t: ^testing.T) {
	item := Chain_List_Item{
		chain_id                      = "chain_123",
		title                         = "Test Chain",
		status                        = "active",
		created_at                    = "2026-09-21T10:00:00Z",
		updated_at                    = "2026-09-21T10:05:00Z",
		coordinator_agent_instance_id = "inst_abc",
		project_id                    = "proj_xyz",
		project_name                  = "Heimdall",
		task_count                    = 5,
		is_pinned                     = true,
		pinned_at                     = "2026-09-21T10:05:00Z",
		completed_task_count          = 3,
		user_validation_count         = 1,
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_chain_list_item_json(&b, item)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"is_pinned":true`), "must serialize is_pinned true")
	testing.expect(t, strings.contains(out, `"pinned_at":"2026-09-21T10:05:00Z"`), "must serialize pinned_at")
	testing.expect(t, strings.contains(out, `"completed_task_count":3`), "must serialize completed_task_count")
	testing.expect(t, strings.contains(out, `"user_validation_count":1`), "must serialize user_validation_count")
}

@(test)
test_write_chain_list_item_json_unpinned :: proc(t: ^testing.T) {
	item := Chain_List_Item{
		chain_id                      = "chain_456",
		title                         = "Unpinned Chain",
		status                        = "active",
		created_at                    = "2026-09-21T10:00:00Z",
		updated_at                    = "2026-09-21T10:05:00Z",
		coordinator_agent_instance_id = "",
		project_id                    = "",
		project_name                  = "",
		task_count                    = 0,
		is_pinned                     = false,
		pinned_at                     = "",
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_chain_list_item_json(&b, item)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"is_pinned":false`), "must serialize is_pinned false")
	testing.expect(t, strings.contains(out, `"pinned_at":""`), "must serialize empty pinned_at")
}

@(test)
test_write_chain_json_pinned :: proc(t: ^testing.T) {
	c := domain.Task_Chain{
		chain_id                      = domain.Task_Chain_ID("chain_pinned_1"),
		owner_user_id                 = domain.User_ID("user_1"),
		title                         = "Pinned Chain Detail",
		description                   = "Description",
		publish_state                 = .Published,
		status                        = .Active,
		kind                          = "team_work",
		coordinator_agent_instance_id = "inst_coord",
		default_reviewer_refs_json    = "[]",
		created_at                    = "2026-09-21T09:00:00Z",
		updated_at                    = "2026-09-21T09:10:00Z",
		is_pinned                     = true,
		pinned_at                     = "2026-09-21T09:10:00Z",
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	write_chain_json(&b, c)
	out := strings.to_string(b)
	testing.expect(t, strings.contains(out, `"is_pinned":true`), "must serialize is_pinned true")
	testing.expect(t, strings.contains(out, `"pinned_at":"2026-09-21T09:10:00Z"`), "must serialize pinned_at")
}
