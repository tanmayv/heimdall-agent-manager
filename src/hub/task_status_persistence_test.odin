package main

// REQ-HUB-STATUS-1 regression + characterisation guards.
//
// change_task_status saves the requested status, then calls
// recompute_chain_promotions, which is ALLOWED to change that status again in the
// same request (reconcile enforces "one In_Progress task per instance" and "zero
// while any task of yours is in_validation", demoting back to Queued at
// promotion.odin:398-400). The bug was not the demotion — that is deliberate
// scheduling — but that the procedure returned the pre-recompute in-memory struct,
// so the API answered ok:true carrying a status the database no longer held.
//
// The invariant these tests protect is therefore NOT "the requested status is
// applied". It is "what we REPORT equals what we PERSIST".

import "core:fmt"
import "core:os"
import "core:testing"
import contracts "odin_test:contracts"
import app "odin_test:hub/app"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"

@(private = "file")
status_fixture :: struct {
	graph:       ^app.App_Graph,
	owner:       string,
	instance_id: string,
	chain_id:    domain.Task_Chain_ID,
	review_task: domain.Task_ID,
	work_task:   domain.Task_ID,
}

// build_status_fixture creates one instance that already has a task IN_VALIDATION
// plus a second Assigned task. That is the exact shape that triggers reconcile's
// "zero in_progress while awaiting review" rule.
@(private = "file")
build_status_fixture :: proc(graph: ^app.App_Graph, owner: string, tag: string) -> status_fixture {
	now := "2026-09-22T00:00:00Z"
	instance_id := fmt.tprintf("inst_%s", tag)

	inst := domain.Agent_Instance{
		agent_instance_id = instance_id,
		agent_id          = fmt.tprintf("agt_%s", tag),
		owner_user_id     = domain.User_ID(owner),
		runtime_status    = "running",
		activity_status   = "idle",
		created_at        = now,
		updated_at        = now,
	}
	_, _, _ = iface.agent_save_instance(graph.taskchains.agents, inst)

	chain_id := domain.Task_Chain_ID(fmt.tprintf("chain_%s", tag))
	chain := domain.Task_Chain{
		chain_id                   = chain_id,
		owner_user_id              = domain.User_ID(owner),
		title                      = "status fixture",
		publish_state              = .Published,
		status                     = .Active,
		default_reviewer_refs_json = "[]",
		created_at                 = now,
		updated_at                 = now,
		published_at               = now,
	}
	_, _, _ = iface.taskchain_save_chain(graph.taskchains.repo, chain)

	assignee := fmt.tprintf(`{"type":"agent_instance","agent_instance_id":"%s"}`, instance_id)

	review_id := domain.Task_ID(fmt.tprintf("task_%s_review", tag))
	review := domain.Task{
		task_id            = review_id,
		chain_id           = chain_id,
		owner_user_id      = domain.User_ID(owner),
		title              = "awaiting review",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		assignee_ref_json  = assignee,
		reviewer_refs_json = "[]",
		created_at         = now,
		updated_at         = now,
		published_at       = now,
	}
	_, _, _ = iface.taskchain_save_task(graph.taskchains.repo, review)

	work_id := domain.Task_ID(fmt.tprintf("task_%s_work", tag))
	work := domain.Task{
		task_id            = work_id,
		chain_id           = chain_id,
		owner_user_id      = domain.User_ID(owner),
		title              = "next work",
		publish_state      = .Published,
		status             = .Assigned,
		priority           = .P2,
		assignee_ref_json  = assignee,
		reviewer_refs_json = "[]",
		created_at         = now,
		updated_at         = now,
		published_at       = now,
	}
	_, _, _ = iface.taskchain_save_task(graph.taskchains.repo, work)

	return status_fixture{graph, owner, instance_id, chain_id, review_id, work_id}
}

@(private = "file")
open_graph :: proc(t: ^testing.T, graph: ^app.App_Graph, tag: string) -> string {
	db_path := fmt.tprintf("/tmp/heimdall-hub-test-status-%s-%d.db", tag, os.get_pid())
	_ = os.remove(db_path)
	cidrs := [?]string{"127.0.0.1/32"}
	ok, msg := app.build_graph(graph, app.Hub_Config{
		database_path        = db_path,
		migrations_dir       = "src/hub/repository/sqlite/migrations",
		username_header      = "X-authentik-username",
		display_name_header  = "X-authentik-name",
		email_header         = "X-authentik-email",
		trusted_proxy_cidrs  = cidrs[:],
		auto_provision_users = true,
		logout_url           = "/_dev/logout",
	})
	testing.expect(t, ok, msg)
	return db_path
}

// THE REGRESSION GUARD. Fails on the pre-fix code, where change_task_status returned
// In_Progress while the row held Queued. Asserts the REPORTED status equals the
// PERSISTED status — deliberately NOT that the requested status was applied, because
// it legitimately is not.
@(test)
test_change_task_status_reports_the_persisted_status :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_graph(t, &graph, "reported")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	f := build_status_fixture(&graph, "alice", "reported")
	auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner}

	reported, changed, _ := taskchain_service.change_task_status(&graph.taskchains, auth, f.work_task, .In_Progress)
	testing.expect(t, changed, "change_task_status should succeed")

	persisted, got, _ := iface.taskchain_get_task(graph.taskchains.repo, f.work_task)
	testing.expect(t, got, "task should still exist after the status change")

	testing.expectf(t, reported.status == persisted.status,
		"API REPORTED %v but the row PERSISTED %v - the response is describing a state the database does not hold",
		reported.status, persisted.status)
}

// CHARACTERISATION, NOT A BUG. The demotion below is INTENDED behaviour: reconcile
// enforces zero in_progress tasks for an instance that has a task awaiting review.
// This test pins that down so nobody later "fixes" the demotion believing it to be
// REQ-HUB-STATUS-1. If this test starts failing, the scheduling rule changed - that
// is a product decision, not a regression to be patched out.
//
// IT IS ALSO WHAT KEEPS TEST 1 HONEST, SO DO NOT DELETE IT AS REDUNDANT. Test 1
// asserts REPORTED == PERSISTED; that holds TRIVIALLY if the fixture ever stops
// producing a demotion, and it would then pass on the very code it exists to catch.
// This test asserts, on the SAME fixture, that the demotion really happens - so the
// pair is load-bearing together: test 2 is the proof that test 1 is not vacuous.
@(test)
test_reconcile_demotes_in_progress_while_instance_awaits_review_by_design :: proc(t: ^testing.T) {
	graph: app.App_Graph
	db_path := open_graph(t, &graph, "demote")
	defer { app.shutdown_graph(&graph); _ = os.remove(db_path) }

	f := build_status_fixture(&graph, "alice", "demote")
	auth := contracts.Auth_Context{kind = .User_Token, user_id = f.owner}

	_, changed, _ := taskchain_service.change_task_status(&graph.taskchains, auth, f.work_task, .In_Progress)
	testing.expect(t, changed, "change_task_status should succeed")

	persisted, got, _ := iface.taskchain_get_task(graph.taskchains.repo, f.work_task)
	testing.expect(t, got, "task should still exist")
	testing.expectf(t, persisted.status == .Queued,
		"expected the promotion engine to demote to Queued while the instance awaits review, got %v",
		persisted.status)
}
