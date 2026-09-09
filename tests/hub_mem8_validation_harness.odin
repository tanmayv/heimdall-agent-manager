package hub_mem8_validation_harness

// MEM-8 end-to-end validation harness (host-safe equivalent of a live dev-stack run).
//
// Drives the REAL hub notification generators (taskchain_service) through a capture
// Bridge_Command_Sink, extracts each emitted human_message with the REAL bridge
// parser (bridge.extract_json_string), and renders the exact agent-facing terminal
// line with the REAL bridge renderer (bridge.bridge_pty_host_task_nudge_line) — the
// same functions the live bridge/pty-host use. This exercises the full hub->bridge
// message path minus only the WS socket hop (which the bridge pty_host unit test
// already covers). It prints an EVENT -> RECIPIENTS -> HUMAN_MESSAGE -> RENDERED
// table with the ACTUAL strings and asserts the MEM-6 formatting/truncation/routing
// rules. No ports, no DB, no external processes.

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import project "odin_test:hub/service/project"
import platform "odin_test:hub/platform"
import bridge "odin_test:bridge"

// ---- fakes ------------------------------------------------------------------

Repo :: struct {
	chain:         domain.Task_Chain,
	task:          domain.Task,
	comments:      [16]domain.Task_Comment,
	comment_count: int,
	members:       [8]domain.Task_Chain_Member,
	member_count:  int,
	seq:           int,
}

Agents :: struct { instances: [16]domain.Agent_Instance, count: int }

Captured :: struct { bodies: [64]string, count: int }
cap_: Captured

clock_now :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-09T17:00:00Z" }
gen_id :: proc(ctx: rawptr, prefix: string) -> string { r := (^Repo)(ctx); r.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)}) }

chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx); if r.chain.chain_id == id do return r.chain, true, {}
	return {}, false, domain.domain_error(.Not_Found, "chain")
}
task_get :: proc(ctx: rawptr, id: domain.Task_ID) -> (domain.Task, bool, domain.Domain_Error) {
	r := (^Repo)(ctx); if r.task.task_id == id do return r.task, true, {}
	return {}, false, domain.domain_error(.Not_Found, "task")
}
comment_save :: proc(ctx: rawptr, c: domain.Task_Comment) -> (domain.Task_Comment, bool, domain.Domain_Error) {
	r := (^Repo)(ctx); r.comments[r.comment_count] = c; r.comment_count += 1; return c, true, {}
}
members_list :: proc(ctx: rawptr, chain_id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<r.member_count do append(&out, r.members[i])
	return out[:], {}
}
make_repo :: proc(r: ^Repo) -> iface.Taskchain_Repository {
	return iface.Taskchain_Repository{ctx = rawptr(r), get_chain = chain_get, get_task = task_get, save_comment = comment_save, list_members_by_chain = members_list}
}

agent_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	a := (^Agents)(ctx)
	for i in 0..<a.count { if a.instances[i].agent_instance_id == id do return a.instances[i], true, {} }
	return {}, false, domain.domain_error(.Not_Found, "instance")
}

capture_send :: proc(ctx: rawptr, command: project.Runtime_Command) -> (bool, domain.Domain_Error) {
	cap_.bodies[cap_.count] = strings.clone(command.body_json); cap_.count += 1; return true, {}
}

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

// render the LAST captured command exactly as the bridge/pty-host would.
render_last :: proc(task_id, role: string) -> (string, string) {
	body := cap_.bodies[cap_.count - 1]
	hm := bridge.extract_json_string(body, "human_message", "")
	line := bridge.bridge_pty_host_task_nudge_line(task_id, role, hm)
	return hm, line
}
row :: proc(event: string, recipients: int, task_id, role: string) -> string {
	hm, line := render_last(task_id, role)
	fmt.printf("ROW\t%s\t%d\t%s\n", event, recipients, line)
	return hm
}

// ---- main -------------------------------------------------------------------

main :: proc() {
	r: Repo
	a: Agents
	// display-name resolution fixtures: assignee/coord/reviewer resolve to @display,
	// inst_nodisp has NO display_name (fallback to @id), user-authored -> @User.
	a.instances[0] = domain.Agent_Instance{agent_instance_id = "inst_assignee", owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "idle", display_name = "coder #7"}
	a.instances[1] = domain.Agent_Instance{agent_instance_id = "inst_coord",    owner_user_id = "alice", bridge_id = "brg_1", runtime_status = "running", display_name = "coord #2"}
	a.instances[2] = domain.Agent_Instance{agent_instance_id = "inst_rev",      owner_user_id = "alice", bridge_id = "brg_2", runtime_status = "idle", display_name = "reviewer #9"}
	a.instances[3] = domain.Agent_Instance{agent_instance_id = "inst_new",      owner_user_id = "alice", bridge_id = "brg_2", runtime_status = "idle", display_name = "coder #12"}
	a.instances[4] = domain.Agent_Instance{agent_instance_id = "inst_nodisp",   owner_user_id = "alice", bridge_id = "brg_3", runtime_status = "idle"}
	a.count = 5

	r.chain = domain.Task_Chain{chain_id = "chain_1", owner_user_id = "alice", coordinator_agent_instance_id = "inst_coord", publish_state = .Published, status = .Active, title = "Ship the thing"}
	r.task = domain.Task{task_id = "task_1", chain_id = "chain_1", owner_user_id = "alice", publish_state = .Published, status = .In_Progress, title = "Fix the thing",
		assignee_ref_json = `{"type":"agent_instance","agent_instance_id":"inst_assignee"}`,
		reviewer_refs_json = `[{"type":"agent_instance","agent_instance_id":"inst_rev"}]`}
	// chain members (for chain-closed broadcast): assignee, coord, reviewer.
	r.members[0] = domain.Task_Chain_Member{chain_id = "chain_1", agent_instance_id = "inst_assignee", owner_user_id = "alice", role = "worker"}
	r.members[1] = domain.Task_Chain_Member{chain_id = "chain_1", agent_instance_id = "inst_coord", owner_user_id = "alice", role = "coordinator"}
	r.members[2] = domain.Task_Chain_Member{chain_id = "chain_1", agent_instance_id = "inst_rev", owner_user_id = "alice", role = "reviewer"}
	r.member_count = 3

	repo := make_repo(&r)
	agents := iface.Agent_Repository{ctx = rawptr(&a), get_instance = agent_get}
	clock := platform.Clock{ctx = nil, now = clock_now}
	ids := platform.ID_Generator{ctx = rawptr(&r), generate = gen_id}
	sink := project.Bridge_Command_Sink{ctx = nil, send_runtime_command = capture_send}
	service := taskchain_service.new_taskchain_service_with_runtime(&repo, &agents, sink, &clock, &ids)

	user_auth := contracts.Auth_Context{kind = .Trusted_Proxy, user_id = "alice"}
	rev_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_rev"}
	coord_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_coord"}

	fmt.println("=== MEM-8 event -> rendered agent-facing line (real generators + real bridge render) ===")

	task := r.task

	// 1) in_progress (Work Started). Actor = assignee. Rendered via status_human_message.
	{
		task.status = .In_Progress
		hm := taskchain_service.status_human_message(&service, task, "inst_assignee")
		defer delete(hm)
		line := bridge.bridge_pty_host_task_nudge_line(string(task.task_id), "assignee", hm)
		defer delete(line)
		fmt.printf("ROW\twork_started(in_progress)\t1\t%s\n", line)
		check(strings.contains(line, `[Work Started] @coder #7 started work on "Fix the thing" (task_1)`), fmt.tprintf("in_progress: %s", line))
	}
	// 2) in_validation (Review Requested). Actor = assignee.
	{
		t := task; t.status = .In_Validation
		hm := taskchain_service.status_human_message(&service, t, "inst_assignee")
		defer delete(hm)
		line := bridge.bridge_pty_host_task_nudge_line(string(t.task_id), "assignee", hm)
		defer delete(line)
		fmt.printf("ROW\treview_requested(in_validation)\t1\t%s\n", line)
		check(strings.contains(line, `[Review Requested] @coder #7 submitted for review "Fix the thing" (task_1)`), fmt.tprintf("in_validation: %s", line))
	}
	// 3) validated_not_good / ngtm (Changes Requested). Actor = reviewer.
	{
		t := task; t.status = .Validated_Not_Good
		hm := taskchain_service.status_human_message(&service, t, "inst_rev")
		defer delete(hm)
		line := bridge.bridge_pty_host_task_nudge_line(string(t.task_id), "assignee", hm)
		defer delete(line)
		fmt.printf("ROW\tchanges_requested(validated_not_good)\t1\t%s\n", line)
		check(strings.contains(line, `[Changes Requested] @reviewer #9 requested changes on "Fix the thing" (task_1)`), fmt.tprintf("ngtm: %s", line))
	}

	// 4) paused -> assignee + coordinator (notify_status_policy). Actor = @User.
	{
		cap_.count = 0
		t := task; t.status = .Paused
		taskchain_service.notify_status_policy(&service, user_auth, t, r.chain)
		check(cap_.count == 2, fmt.tprintf("paused must wake assignee + coordinator, got %d", cap_.count))
		hm := row("paused", 2, "task_1", "assignee")
		check(strings.contains(hm, `[Task Paused] @User paused "Fix the thing" (task_1)`), fmt.tprintf("paused: %s", hm))
	}
	// 5) cancelled -> assignee + coordinator.
	{
		cap_.count = 0
		t := task; t.status = .Cancelled
		taskchain_service.notify_status_policy(&service, user_auth, t, r.chain)
		check(cap_.count == 2, fmt.tprintf("cancelled must wake assignee + coordinator, got %d", cap_.count))
		hm := row("cancelled", 2, "task_1", "assignee")
		check(strings.contains(hm, `[Task Cancelled] @User cancelled "Fix the thing" (task_1)`), fmt.tprintf("cancelled: %s", hm))
	}
	// 6) validated_good -> coordinator only.
	{
		cap_.count = 0
		t := task; t.status = .Validated_Good
		taskchain_service.notify_status_policy(&service, user_auth, t, r.chain)
		check(cap_.count == 1, fmt.tprintf("validated_good must wake only coordinator, got %d", cap_.count))
		hm := row("validated_good", 1, "task_1", "coordinator")
		check(strings.contains(hm, `[Review Consensus] @User marked ready for sign-off "Fix the thing" (task_1)`), fmt.tprintf("validated_good: %s", hm))
	}

	// 7) targeted comment (--notify inst_assignee) authored by coordinator -> [Comment].
	{
		cap_.count = 0
		targets := [?]string{"inst_assignee"}
		_, notified, ok, _ := taskchain_service.comment_task(&service, coord_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "please rebase onto main", notify = targets[:]})
		check(ok && len(notified) == 1 && notified[0] == "inst_assignee", "targeted comment must notify exactly the target")
		hm := row("comment_targeted(--notify)", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Comment] @coord #2 commented on "Fix the thing" (task_1): "please rebase onto`) && strings.contains(hm, `…"`) && !strings.contains(hm, "main"), fmt.tprintf("targeted comment: %s", hm))
	}
	// 8) USER comment (no --notify) -> all role-holders: coordinator + assignee + reviewer.
	{
		cap_.count = 0
		_, notified, ok, _ := taskchain_service.comment_task(&service, user_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "looks good, ship it"})
		check(ok, "user comment must save")
		check(cap_.count == 3 && len(notified) == 3, fmt.tprintf("user comment must wake coordinator+assignee+reviewer, got %d", cap_.count))
		joined := strings.concatenate({cap_.bodies[0], cap_.bodies[1], cap_.bodies[2]})
		defer delete(joined)
		check(strings.contains(joined, `"agent_instance_id":"inst_coord"`) && strings.contains(joined, `"agent_instance_id":"inst_assignee"`) && strings.contains(joined, `"agent_instance_id":"inst_rev"`), "user comment must target all three role-holders")
		hm := row("comment_user(all role-holders)", 3, "task_1", "assignee")
		check(strings.contains(hm, `[Comment] @User commented on "Fix the thing" (task_1): "looks good, ship it"`), fmt.tprintf("user comment: %s", hm))
	}
	// 9) AGENT comment (assignee author) -> coordinator gets [Progress Update].
	{
		cap_.count = 0
		asg_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = "inst_assignee"}
		_, _, ok, _ := taskchain_service.comment_task(&service, asg_auth, taskchain_service.Task_Comment_Input{task_id = "task_1", body = "pushed WIP commit"})
		check(ok, "agent comment must save")
		check(cap_.count == 1, fmt.tprintf("agent comment (no --notify) wakes only coordinator, got %d", cap_.count))
		hm := row("comment_agent->coordinator", 1, "task_1", "coordinator")
		check(strings.contains(hm, `[Progress Update] @coder #7 posted an update on "Fix the thing" (task_1): "pushed WIP commit"`), fmt.tprintf("agent comment: %s", hm))
	}

	// 10) nudge WITH message (send_task_wake origin=nudge, tag=Nudge verb="nudged on").
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "nudge", "Nudge", "nudged on", "please pick this up now", "inst_coord")
		check(sent && cap_.count == 1, "nudge-with-message must emit one wake")
		hm := row("nudge_with_message", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Nudge] @coord #2 nudged on "Fix the thing" (task_1): "please pick this up`) && strings.contains(hm, `…"`) && !strings.contains(hm, "now"), fmt.tprintf("nudge w/ msg: %s", hm))
	}
	// 11) nudge WITHOUT message (no excerpt tail).
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "nudge", "Nudge", "nudged on", "", "inst_coord")
		check(sent && cap_.count == 1, "nudge-no-message must emit one wake")
		hm := row("nudge_no_message", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Nudge] @coord #2 nudged on "Fix the thing" (task_1)`) && !strings.contains(hm, `: "`), fmt.tprintf("nudge no msg: %s", hm))
	}

	// 12) set-current / focus switch (notify_current_task_changed, role work).
	{
		cap_.count = 0
		inst_a := a.instances[0]
		taskchain_service.notify_current_task_changed(&service, inst_a, task, .Work)
		check(cap_.count == 1, "focus switch must emit one wake")
		hm := row("focus_switch(set-current)", 1, "task_1", "work")
		check(strings.contains(hm, `[Focus Switched] Your active focus changed to "Fix the thing" (task_1) (Role: work)`), fmt.tprintf("focus switch: %s", hm))
	}

	// 13) vote LGTM (quorum) -> assignee gets [Task Approved]. Actor = reviewer.
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "vote", "Task Approved", "voted LGTM on", "ship it, clean", "inst_rev")
		check(sent, "vote-approved wake must emit")
		hm := row("vote_lgtm_quorum->assignee", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Task Approved] @reviewer #9 voted LGTM on "Fix the thing" (task_1): "ship it, clean"`), fmt.tprintf("vote approved: %s", hm))
	}
	// 14) vote LGTM (partial) -> coordinator gets [Review Progress].
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_coord", "vote", "Review Progress", "voted LGTM on", "one down", "inst_rev")
		check(sent, "vote-progress wake must emit")
		hm := row("vote_lgtm_partial->coordinator", 1, "task_1", "coordinator")
		check(strings.contains(hm, `[Review Progress] @reviewer #9 voted LGTM on "Fix the thing" (task_1): "one down"`), fmt.tprintf("vote progress: %s", hm))
	}
	// 15) vote NGTM -> coordinator gets [Changes Requested].
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_coord", "vote", "Changes Requested", "requested changes on", "needs tests", "inst_rev")
		check(sent, "vote-ngtm wake must emit")
		hm := row("vote_ngtm->coordinator", 1, "task_1", "coordinator")
		check(strings.contains(hm, `[Changes Requested] @reviewer #9 requested changes on "Fix the thing" (task_1): "needs tests"`), fmt.tprintf("vote ngtm: %s", hm))
	}

	// 16) assign on active chain -> assignee [Task Assigned] "assigned to you". Actor = @User.
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "assigned", "Task Assigned", "assigned to you", "", "")
		check(sent, "assign->assignee wake must emit")
		hm := row("assign->assignee", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Task Assigned] @User assigned to you "Fix the thing" (task_1)`), fmt.tprintf("assign assignee: %s", hm))
	}
	// 17) assign -> coordinator informed [Task Assigned] "assigned".
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_coord", "assigned", "Task Assigned", "assigned", "", "")
		check(sent, "assign->coord wake must emit")
		hm := row("assign->coordinator", 1, "task_1", "coordinator")
		check(strings.contains(hm, `[Task Assigned] @User assigned "Fix the thing" (task_1)`), fmt.tprintf("assign coord: %s", hm))
	}
	// 18) dependency unblock / reassign -> new assignee [Task Reassigned].
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_new", "reassigned", "Task Reassigned", "reassigned to you", "", "")
		check(sent, "reassign wake must emit")
		hm := row("reassign->new_assignee", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Task Reassigned] @User reassigned to you "Fix the thing" (task_1)`), fmt.tprintf("reassign: %s", hm))
	}
	// 19) priority escalation -> assignee [Priority P0].
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "priority", "Priority P0", "escalated to P0", "", "")
		check(sent, "priority wake must emit")
		hm := row("priority_escalation", 1, "task_1", "assignee")
		check(strings.contains(hm, `[Priority P0] @User escalated to P0 "Fix the thing" (task_1)`), fmt.tprintf("priority: %s", hm))
	}

	// 20) chain complete broadcast -> every live member except the actor.
	{
		cap_.count = 0
		taskchain_service.broadcast_chain_closed(&service, coord_auth, r.chain, .Completed)
		// members = assignee, coord, reviewer; actor = coord -> 2 recipients.
		check(cap_.count == 2, fmt.tprintf("chain closed must wake members minus actor, got %d", cap_.count))
		hm := row("chain_closed(completed broadcast)", 2, "", "member")
		check(strings.contains(hm, `[Chain Closed] Task chain "Ship the thing" (chain_1) was marked completed by @coord #2. All task activities halted.`), fmt.tprintf("chain closed completed: %s", hm))
	}
	// 20b) chain CANCELLED broadcast -> every live member except the actor.
	{
		cap_.count = 0
		taskchain_service.broadcast_chain_closed(&service, coord_auth, r.chain, .Cancelled)
		check(cap_.count == 2, fmt.tprintf("chain cancelled must wake members minus actor, got %d", cap_.count))
		hm := row("chain_closed(cancelled broadcast)", 2, "", "member")
		check(strings.contains(hm, `[Chain Closed] Task chain "Ship the thing" (chain_1) was marked cancelled by @coord #2. All task activities halted.`), fmt.tprintf("chain closed cancelled: %s", hm))
	}

	// ---- targeted checks: display-name fallback, @User, truncation, self-not-woken --

	fmt.println("=== targeted checks ===")

	// display-name FALLBACK to @id when the actor instance has no display_name.
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "nudge", "Nudge", "nudged on", "", "inst_nodisp")
		check(sent, "fallback wake must emit")
		hm, line := render_last("task_1", "assignee")
		fmt.printf("ROW\tdisplay_name_fallback(@id)\t1\t%s\n", line)
		check(strings.contains(hm, `[Nudge] @inst_nodisp nudged on "Fix the thing" (task_1)`), fmt.tprintf("fallback: %s", hm))
	}

	// TITLE truncation to 20 runes + ellipsis.
	{
		cap_.count = 0
		lt := task; lt.title = "This Task Title Is Way Too Long To Fit"
		sent := taskchain_service.send_task_wake(&service, lt, "inst_assignee", "status", "Work Started", "started work on", "", "inst_coord")
		check(sent, "long-title wake must emit")
		hm, line := render_last("task_1", "assignee")
		fmt.printf("ROW\ttitle_truncation(20)\t1\t%s\n", line)
		check(strings.contains(hm, `"This Task Title Is W…"`), fmt.tprintf("title trunc: %s", hm))
		check(!strings.contains(hm, "Too Long"), "title must not exceed 20 runes")
	}

	// EXCERPT truncation to 20 runes + ellipsis (free-text tail).
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "nudge", "Nudge", "nudged on", "0123456789ABCDEFGHIJ_OVERFLOW_TAIL", "inst_coord")
		check(sent, "long-excerpt wake must emit")
		hm, line := render_last("task_1", "assignee")
		fmt.printf("ROW\texcerpt_truncation(20)\t1\t%s\n", line)
		check(strings.contains(hm, `: "0123456789ABCDEFGHIJ…"`), fmt.tprintf("excerpt trunc: %s", hm))
		check(!strings.contains(hm, "OVERFLOW"), "excerpt must not exceed 20 runes")
	}

	// actor is NEVER self-woken (worker-interrupt protection): target == actor -> no emit.
	{
		cap_.count = 0
		sent := taskchain_service.send_task_wake(&service, task, "inst_assignee", "status", "Work Started", "started work on", "", "inst_assignee")
		check(!sent && cap_.count == 0, "self-wake must be suppressed (actor == target)")
		fmt.println("ROW\tself_wake_suppressed\t0\t(no command emitted — actor never wakes itself)")
	}

	fmt.println("PASS: hub mem8 validation harness")
}
