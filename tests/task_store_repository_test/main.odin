package task_store_repository_test

// Phase 0 accessor coverage for docs/plans/task-store-repository.md.
// Verifies the new typed query/mutation surface behaves identically to the
// hand-rolled scans/index math it will eventually replace, without any
// behavior change to the underlying globals.

import "core:fmt"
import "core:os"
import daemon "odin_test:daemon"

main :: proc() {
	data_dir := "/tmp/heimdall-task-store-repo-test"
	_, _, _, _ = os.process_exec(os.Process_Desc{command = []string{"rm", "-rf", data_dir}}, context.allocator)
	daemon.task_store_init(data_dir)

	// --- Chains ---
	check(daemon.store_upsert_chain(daemon.Task_Chain_State{chain_id = "chain-a", project_id = "proj-1", status = "active", title = "Chain A"}), "upsert chain-a failed")
	check(daemon.store_upsert_chain(daemon.Task_Chain_State{chain_id = "chain-b", project_id = "proj-1", status = "active", title = "Chain B"}), "upsert chain-b failed")
	check(daemon.store_upsert_chain(daemon.Task_Chain_State{chain_id = "chain-c", project_id = "proj-2", status = "active", title = "Chain C"}), "upsert chain-c failed")

	check(daemon.store_chain_exists("chain-a"), "chain-a should exist")
	check(!daemon.store_chain_exists("missing"), "missing chain must not exist")
	chain, ok := daemon.store_get_chain("chain-b")
	check(ok && chain.title == "Chain B", "store_get_chain should return chain-b by value")
	_, missing_ok := daemon.store_get_chain("missing")
	check(!missing_ok, "store_get_chain must report not-found")

	// Upsert-by-id must replace, not duplicate.
	before_count := daemon.store_chain_count()
	check(daemon.store_upsert_chain(daemon.Task_Chain_State{chain_id = "chain-a", project_id = "proj-1", status = "completed", title = "Chain A v2"}), "re-upsert chain-a failed")
	check(daemon.store_chain_count() == before_count, "re-upsert must not grow chain count")
	updated, _ := daemon.store_get_chain("chain-a")
	check(updated.title == "Chain A v2" && updated.status == "completed", "re-upsert must replace chain-a fields")

	proj1_chains := daemon.store_chains_for_project("proj-1")
	check(len(proj1_chains) == 2, "proj-1 should have two chains")
	proj2_chains := daemon.store_chains_for_project("proj-2")
	check(len(proj2_chains) == 1, "proj-2 should have one chain")

	// --- Tasks ---
	check(daemon.store_upsert_task(daemon.Task_State{task_id = "t1", chain_id = "chain-a", title = "T1", assignee_agent_instance_id = "worker@x"}), "upsert t1 failed")
	check(daemon.store_upsert_task(daemon.Task_State{task_id = "t2", chain_id = "chain-a", title = "T2", assignee_agent_instance_id = "worker@y"}), "upsert t2 failed")
	check(daemon.store_upsert_task(daemon.Task_State{task_id = "t3", chain_id = "chain-b", title = "T3", assignee_agent_instance_id = "worker@x"}), "upsert t3 failed")

	check(daemon.store_task_exists("t1"), "t1 should exist")
	check(!daemon.store_task_exists("nope"), "nonexistent task must not exist")
	task, task_ok := daemon.store_get_task("t2")
	check(task_ok && task.title == "T2", "store_get_task should return t2")

	// find-then-index replacement with chain scoping
	scoped, scoped_ok := daemon.store_get_task_in_chain("t1", "chain-a")
	check(scoped_ok && scoped.title == "T1", "store_get_task_in_chain should match chain")
	_, wrong_chain_ok := daemon.store_get_task_in_chain("t1", "chain-b")
	check(!wrong_chain_ok, "store_get_task_in_chain must reject wrong chain")
	any_chain, any_ok := daemon.store_get_task_in_chain("t1", "")
	check(any_ok && any_chain.title == "T1", "empty chain_id should match any chain")

	chain_a_tasks := daemon.store_tasks_in_chain("chain-a")
	check(len(chain_a_tasks) == 2, "chain-a should have two tasks")
	worker_x_tasks := daemon.store_tasks_for_assignee("worker@x")
	check(len(worker_x_tasks) == 2, "worker@x should have two tasks across chains")

	// re-upsert replaces, no duplicate
	tcount := daemon.store_task_count()
	check(daemon.store_upsert_task(daemon.Task_State{task_id = "t1", chain_id = "chain-a", title = "T1 v2"}), "re-upsert t1 failed")
	check(daemon.store_task_count() == tcount, "re-upsert must not grow task count")
	t1v2, _ := daemon.store_get_task("t1")
	check(t1v2.title == "T1 v2", "re-upsert must replace t1 title")

	// --- Participants ---
	check(daemon.store_add_participant(daemon.Task_Participant{task_id = "t1", chain_id = "chain-a", agent_instance_id = "rev@x", role = "lgtm_required"}), "add participant failed")
	check(daemon.store_add_participant(daemon.Task_Participant{task_id = "t1", chain_id = "chain-a", agent_instance_id = "rev@x", role = "lgtm_required"}), "idempotent add should return true")
	check(!daemon.store_add_participant(daemon.Task_Participant{task_id = "t1", agent_instance_id = "", role = "lgtm_required"}), "empty agent must be rejected")
	check(daemon.store_actor_has_role("t1", "rev@x", "lgtm_required"), "store_actor_has_role should find participant")
	check(!daemon.store_actor_has_role("t1", "rev@x", "assignee"), "wrong role must not match")
	parts := daemon.store_participants_of("t1")
	check(len(parts) == 1, "t1 should have exactly one participant after idempotent add")
	check(daemon.store_remove_participant("t1", "rev@x", "lgtm_required"), "remove participant should report change")
	check(!daemon.store_remove_participant("t1", "rev@x", "lgtm_required"), "removing absent participant returns false")
	check(!daemon.store_actor_has_role("t1", "rev@x", "lgtm_required"), "participant should be gone after remove")

	// --- Comments ---
	check(daemon.store_add_comment(daemon.Task_Comment_State{comment_id = "c1", task_id = "t1", chain_id = "chain-a", body = "hello"}), "add comment failed")
	comments := daemon.store_comments_of("t1")
	check(len(comments) == 1 && comments[0].body == "hello", "store_comments_of should return the added comment")

	// --- Votes ---
	check(daemon.store_record_vote(daemon.Task_LGTM_Vote_State{task_id = "t1", chain_id = "chain-a", reviewer_agent_instance_id = "rev@x", approved = true, role = "lgtm_required"}), "record vote failed")
	check(daemon.store_reviewer_has_voted("t1", "rev@x"), "reviewer should be recorded as voted")
	check(!daemon.store_reviewer_has_voted("t1", "rev@y"), "unrelated reviewer must not be voted")
	// re-record same reviewer updates in place (no dup)
	check(daemon.store_record_vote(daemon.Task_LGTM_Vote_State{task_id = "t1", chain_id = "chain-a", reviewer_agent_instance_id = "rev@x", approved = false, role = "lgtm_required"}), "re-record vote failed")
	votes := daemon.store_votes_for("t1")
	check(len(votes) == 1, "same reviewer must not duplicate votes")
	check(votes[0].approved == false, "re-record must update the vote in place")
	check(daemon.store_clear_votes_for_task("t1"), "clear votes failed")
	check(len(daemon.store_votes_for("t1")) == 0, "votes should be cleared")
	check(!daemon.store_reviewer_has_voted("t1", "rev@x"), "reviewer should no longer be recorded")

	fmt.println("PASS: task store repository accessor surface")
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln("FAIL:", message)
	os.exit(1)
}
