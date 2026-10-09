package http

// REQ-P2-TASKCHAIN-HANDLERS test suite:
// Verifies typed struct serialization for taskchain HTTP wire models via core:encoding/json,
// typed actor ref query filtering (preventing substring false-positives),
// special character/markdown escaping resilience, and zero leaks under Tracking_Allocator.

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_task_wire_escaped_characters_and_markdown :: proc(t: ^testing.T) {
	special_title := "Fix: \"quotes\" & \\backslashes\\ and \n newlines \t tabs <tag> [link](url)"
	special_desc := "Line 1\nLine 2\n```odin\nmain :: proc() { fmt.println(\"hello\\n\"); }\n```\nPath: C:\\Windows\\System32"

	task := domain.Task{
		task_id            = domain.Task_ID("task_escape_1"),
		chain_id           = domain.Task_Chain_ID("chain_escape_1"),
		owner_user_id      = domain.User_ID("usr_admin"),
		title              = special_title,
		description        = special_desc,
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P1,
		bridge_id          = "brg_123",
		assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_worker_1"}`,
		reviewer_refs_json = `[{"type":"user","user_id":"usr_admin"}]`,
		updated_at         = "2026-10-03T12:00:00Z",
	}

	b := strings.builder_make(context.temp_allocator)
	write_task_json(&b, task)
	payload := strings.to_string(b)

	val, err := json.parse_string(payload, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err == .None, "marshaled task json must parse cleanly")

	#partial switch obj in val {
	case json.Object:
		title_val, ok1 := obj["title"].(json.String)
		testing.expect(t, ok1, "title field must be present as a string")
		testing.expect_value(t, string(title_val), special_title)

		desc_val, ok2 := obj["description"].(json.String)
		testing.expect(t, ok2, "description field must be present as a string")
		testing.expect_value(t, string(desc_val), special_desc)

		bridge_val, ok3 := obj["bridge_id"].(json.String)
		testing.expect(t, ok3, "bridge_id must be present as a string")
		testing.expect_value(t, string(bridge_val), "brg_123")

		requires_approval, ok4 := obj["requires_user_approval"].(json.Boolean)
		testing.expect(t, ok4 && bool(requires_approval), "wire task must derive requires_user_approval")
		reviewers := obj["reviewer_refs"].(json.Array)
		reviewer := reviewers[0].(json.Object)
		username, username_ok := reviewer["username"].(json.String)
		testing.expect(t, username_ok, "user reviewer wire entry must include username")
		testing.expect_value(t, string(username), "usr_admin")
	case:
		testing.fail_now(t, "expected json.Object payload")
	}
}

@(test)
test_task_matches_query_actor_ref_resilience_and_no_substring_false_positives :: proc(t: ^testing.T) {
	// Keys reversed with extra spaces
	task1 := domain.Task{
		task_id            = domain.Task_ID("task_1"),
		assignee_ref_json  = `  { "display_name": "worker #1",  "agent_instance_id": "inst_123", "type": "agent_instance" }  `,
		reviewer_refs_json = ` [ { "user_id": "usr_reviewer_1", "type": "user" }, { "agent_instance_id": "inst_rev_2", "type": "agent_instance" } ] `,
	}

	// 1. Exact match works despite whitespace and key reordering
	testing.expect(t, task_matches_query(task1, "assignee_agent_instance_id=inst_123"), "exact assignee must match")
	testing.expect(t, task_matches_query(task1, "reviewer_agent_instance_id=inst_rev_2"), "exact reviewer agent must match")
	testing.expect(t, task_matches_query(task1, "reviewer_user_id=usr_reviewer_1"), "exact reviewer user must match")

	// 2. Substring matching is strictly rejected (preventing false positives)
	testing.expect(t, !task_matches_query(task1, "assignee_agent_instance_id=inst_12"), "prefix substring must NOT match")
	testing.expect(t, !task_matches_query(task1, "assignee_agent_instance_id=23"), "suffix substring must NOT match")
	testing.expect(t, !task_matches_query(task1, "reviewer_agent_instance_id=inst_rev"), "reviewer prefix substring must NOT match")
	testing.expect(t, !task_matches_query(task1, "reviewer_user_id=usr_rev"), "reviewer user prefix substring must NOT match")

	// 3. Different ID does not match
	testing.expect(t, !task_matches_query(task1, "assignee_agent_instance_id=inst_other"), "different assignee must not match")
	testing.expect(t, !task_matches_query(task1, "reviewer_agent_instance_id=inst_other"), "different reviewer agent must not match")
	testing.expect(t, !task_matches_query(task1, "reviewer_user_id=usr_other"), "different reviewer user must not match")

	// 4. Combined queries require both to match
	testing.expect(t, task_matches_query(task1, "reviewer_user_id=usr_reviewer_1&reviewer_agent_instance_id=inst_rev_2"), "both matching reviewer query params must match")
	testing.expect(t, !task_matches_query(task1, "reviewer_user_id=usr_reviewer_1&reviewer_agent_instance_id=inst_other"), "mismatched reviewer agent in combined query must fail")
}

@(test)
test_taskchain_typed_wire_tracking_allocator_clean :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	// Perform operations that serialize wire models using temp_allocator or local scopes
	for _ in 0..<10 {
		b := strings.builder_make(context.temp_allocator)
		task := domain.Task{
			task_id            = domain.Task_ID("task_leak_check"),
			chain_id           = domain.Task_Chain_ID("chain_leak_check"),
			title              = "Leak check task",
			description        = "Verifying zero heap leaks",
			publish_state      = .Published,
			status             = .Assigned,
			priority           = .P0,
			assignee_ref_json  = `{"type":"agent_instance","agent_instance_id":"inst_leak"}`,
			reviewer_refs_json = `[]`,
			updated_at         = "2026-10-03T12:00:00Z",
		}
		write_task_json(&b, task)

		matched := task_matches_query(task, "assignee_agent_instance_id=inst_leak")
		testing.expect(t, matched, "task should match")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	if len(track.allocation_map) > 0 {
		testing.fail_now(t, "Memory leak detected in taskchain typed wire operations")
	}
}

@(test)
test_task_comment_and_vote_wire_serialization :: proc(t: ^testing.T) {
	vote := domain.Task_Vote{
		task_id                   = domain.Task_ID("task_v1"),
		chain_id                  = domain.Task_Chain_ID("chain_v1"),
		owner_user_id             = domain.User_ID("usr_v1"),
		reviewer_agent_instance_id = "inst_rev_1",
		vote                      = "lgtm",
		comment                   = "Looks great! \"Special quotes\" and \nnewlines.",
		created_at                = "2026-10-03T12:00:00Z",
	}

	b := strings.builder_make(context.temp_allocator)
	write_task_vote_json(&b, vote)
	vote_payload := strings.to_string(b)

	val, err := json.parse_string(vote_payload, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err == .None, "vote json must parse cleanly")
	#partial switch obj in val {
	case json.Object:
		testing.expect_value(t, string(obj["vote"].(json.String)), "lgtm")
		testing.expect_value(t, string(obj["comment"].(json.String)), vote.comment)
		testing.expect_value(t, string(obj["reviewer_agent_instance_id"].(json.String)), "inst_rev_1")
	case:
		testing.fail_now(t, "expected json.Object payload for vote")
	}

	comment := domain.Task_Comment{
		comment_id               = "cmt_1",
		task_id                  = domain.Task_ID("task_c1"),
		chain_id                 = domain.Task_Chain_ID("chain_c1"),
		author_agent_instance_id = "inst_c1",
		owner_user_id            = domain.User_ID("usr_c1"),
		body                     = "Comment body with *markdown* and \\slashes",
		created_at               = "2026-10-03T12:01:00Z",
	}

	b2 := strings.builder_make(context.temp_allocator)
	write_task_comment_json(&b2, comment, "Agent Worker Alpha")
	cmt_payload := strings.to_string(b2)

	val2, err2 := json.parse_string(cmt_payload, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	testing.expect(t, err2 == .None, "comment json must parse cleanly")
	#partial switch obj2 in val2 {
	case json.Object:
		testing.expect_value(t, string(obj2["author_display_name"].(json.String)), "Agent Worker Alpha")
		testing.expect_value(t, string(obj2["body"].(json.String)), comment.body)
		testing.expect_value(t, string(obj2["author_user_id"].(json.String)), "usr_c1")
	case:
		testing.fail_now(t, "expected json.Object payload for comment")
	}
}
