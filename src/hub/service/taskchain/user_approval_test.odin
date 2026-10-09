package taskchain

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_owner_user_approval_ref_is_derived_and_mutated_idempotently :: proc(t: ^testing.T) {
	base := `[{"type":"agent_id","agent_id":"agt_review"}]`
	with_user, ok := set_owner_user_approval(base, "alice", true, context.temp_allocator)
	testing.expect(t, ok, "enabling user approval must succeed")
	testing.expect(t, strings.contains(with_user, `"user_id":"alice"`), "owner user ref must be added")
	testing.expect(t, strings.contains(with_user, `"agent_id":"agt_review"`), "agent reviewer must be preserved")

	twice, twice_ok := set_owner_user_approval(with_user, "alice", true, context.temp_allocator)
	testing.expect(t, twice_ok, "repeated enable must succeed")
	refs, _, parsed := parse_actor_refs(twice, context.temp_allocator)
	testing.expect(t, parsed, "result must parse")
	user_count := 0
	for ref in refs do if ref.type == "user" && ref.user_id == "alice" do user_count += 1
	testing.expect_value(t, user_count, 1)

	without_user, removed_ok := set_owner_user_approval(twice, "alice", false, context.temp_allocator)
	testing.expect(t, removed_ok, "disabling user approval must succeed")
	testing.expect(t, !strings.contains(without_user, `"user_id"`), "owner user ref must be removed")
	testing.expect(t, strings.contains(without_user, `"agent_id":"agt_review"`), "agent reviewer must remain")
}

@(test)
test_replacing_agent_reviewers_can_preserve_owner_gate :: proc(t: ^testing.T) {
	replacement := `[{"type":"agent_id","agent_id":"agt_new"}]`
	preserved, ok := set_owner_user_approval(replacement, "alice", true, context.temp_allocator)
	testing.expect(t, ok, "preserving the user gate must succeed")
	testing.expect(t, strings.contains(preserved, `"agent_id":"agt_new"`), "replacement agent reviewer must remain")
	testing.expect(t, strings.contains(preserved, `"user_id":"alice"`), "owner gate must remain when the boolean is omitted")
}

@(test)
test_task_requires_user_approval_requires_exact_owner_ref :: proc(t: ^testing.T) {
	owner_task := domain.Task{owner_user_id = domain.User_ID("alice"), reviewer_refs_json = `[{"type":"user","user_id":"alice"}]`}
	other_task := domain.Task{owner_user_id = domain.User_ID("alice"), reviewer_refs_json = `[{"type":"user","user_id":"bob"}]`}
	testing.expect(t, task_requires_user_approval(owner_task), "exact owner ref must enable approval")
	testing.expect(t, !task_requires_user_approval(other_task), "another user ref must not enable approval")
}
