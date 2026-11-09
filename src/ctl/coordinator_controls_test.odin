package main

import "core:strings"
import "core:testing"

@(test)
test_coord_plan_methods_and_reasons :: proc(t: ^testing.T) {
	cases := [?]struct{ verb, method, hub: string }{
		{"hold", "agent.task.hold", "hold"},
		{"release", "agent.task.release", "release"},
		{"unblock", "agent.task.unblock", "answer"},
		{"recheck", "agent.task.recheck", "recheck"},
		{"cancel", "agent.task.cancel", ""},
		{"reopen", "agent.task.reopen", ""},
		{"delete", "agent.task.delete", ""},
		{"escalate", "agent.task.escalate", ""},
		{"merge-retry", "agent.task.merge_retry", ""},
		{"revoke", "agent.lease.revoke", ""},
	}
	for c in cases {
		plan := ctl_coord_plan(c.verb, "task_1", []string{"--reason", "why"})
		testing.expectf(t, plan.error == "", "%s: %s", c.verb, plan.error)
		testing.expect_value(t, plan.method, c.method)
		testing.expect_value(t, plan.hub_action, c.hub)
		testing.expectf(t, strings.contains(plan.params, `"task_id":"task_1"`) && strings.contains(plan.params, `"reason":"why"`), "%s params %s", c.verb, plan.params)
	}
	// Verbs whose owner method requires a reason refuse before sending anything.
	for verb in ([?]string{"hold", "cancel", "reopen", "delete", "escalate", "merge-retry", "revoke", "done", "split", "submit-for-review"}) {
		plan := ctl_coord_plan(verb, "task_1", []string{"--force", "--summary", "s"}, `[{"title":"a"}]`)
		testing.expectf(t, strings.contains(plan.error, "--reason"), "%s without --reason: %q", verb, plan.error)
	}
	// release / recheck stay optional (the legacy Hub routes accept them).
	testing.expect_value(t, ctl_coord_plan("release", "task_1", nil).error, "")
	testing.expect_value(t, ctl_coord_plan("recheck", "task_1", nil).error, "")
	// unblock accepts --note as its reason.
	unblock := ctl_coord_plan("unblock", "task_1", []string{"--note", "fixed placement"})
	testing.expect(t, strings.contains(unblock.params, `"reason":"fixed placement"`), "unblock --note is the reason")
	testing.expect(t, ctl_coord_plan("cancel", "", []string{"--reason", "x"}).error != "", "task id required")
	chain := ctl_coord_plan("hold", "task_1", []string{"--reason", "x", "--chain", "chain_1"})
	testing.expect(t, strings.contains(chain.params, `"chain_id":"chain_1"`), "--chain forwarded")
}

// REQ T1-1/2: routing after the Bridge's first answer.
@(test)
test_coord_route_owner_only_and_refusals :: proc(t: ^testing.T) {
	owner_only := `{"v":1,"id":"r","ok":false,"error":{"code":"bad_request","message":"owner_chain_only: this coordinator control is served only for chains owned by this Bridge; the target chain is not one of them"}}`
	// A legacy Hub chain: every owner control answers the typed error.
	for verb in ([?]string{"cancel", "reopen", "delete", "escalate", "merge-retry", "revoke", "done", "submit-for-review", "split", "review-roles"}) {
		plan := ctl_coord_plan(verb, "task_1", []string{"--reason", "x", "--force", "--summary", "s", "--role", "reviewer=agt_r"}, `[{"title":"a"}]`)
		testing.expectf(t, plan.error == "", "%s: %s", verb, plan.error)
		testing.expectf(t, ctl_coord_route(plan, owner_only) == .Owner_Only, "%s on a Hub chain is owner_chain_only", verb)
		typed := ctl_coord_owner_only_json(verb)
		testing.expectf(t, strings.contains(typed, `"ok":false`) && strings.contains(typed, `"code":"owner_chain_only"`) && strings.contains(typed, "legacy Hub chain"), "%s typed error: %s", verb, typed)
	}
	// The verbs ham-ctl already sent to the Hub keep their routes.
	testing.expect_value(t, ctl_coord_route(ctl_coord_plan("hold", "task_1", []string{"--reason", "x"}), owner_only), Ctl_Coord_Route.Hub)
	// Refusals are printed, never turned into owner_chain_only: a worker token,
	// a reviewer token and a coordinator of another chain.
	worker := `{"v":1,"id":"r","ok":false,"error":{"code":"invalid_scope","message":"refused: only the verified chain coordinator may use this control"}}`
	reviewer := `{"v":1,"id":"r","ok":false,"error":{"code":"invalid_scope","message":"refused: only the chain coordinator may do this, and a task escalated to a human is cleared only by the user from the Heimdall app"}}`
	other_chain := `{"v":1,"id":"r","ok":false,"error":{"code":"invalid_scope","message":"refused: only the verified chain coordinator may use this control"}}`
	for refusal in ([?]string{worker, reviewer, other_chain}) {
		testing.expect_value(t, ctl_coord_route(ctl_coord_plan("cancel", "task_1", []string{"--reason", "x"}), refusal), Ctl_Coord_Route.Print)
		testing.expect_value(t, ctl_coord_route(ctl_coord_plan("hold", "task_1", []string{"--reason", "x"}), refusal), Ctl_Coord_Route.Print)
		testing.expect(t, strings.contains(ctl_coord_refusal_cause(refusal), "not this chain's coordinator"), "the cause names the coordinator requirement")
	}
	ok := `{"v":1,"id":"r","ok":true,"data":{"task_id":"task_1"}}`
	testing.expect_value(t, ctl_coord_route(ctl_coord_plan("cancel", "task_1", []string{"--reason", "x"}), ok), Ctl_Coord_Route.Print)
	testing.expect_value(t, ctl_coord_refusal_cause(ok), "")
}

// REQ T1-5: a refused reopen names its cause (supplied by the owner Bridge).
@(test)
test_coord_reopen_refusal_causes :: proc(t: ^testing.T) {
	consumed := `{"v":1,"id":"r","ok":false,"error":{"code":"operation_conflict","message":"task cannot be reopened: consumed by a started dependent (task second); create replacement work instead"}}`
	testing.expect_value(t, ctl_coord_refusal_cause(consumed), "consumed by a started dependent (task second); create replacement work instead")
	inactive := `{"v":1,"id":"r","ok":false,"error":{"code":"operation_conflict","message":"task cannot be reopened: chain not active (status completed)"}}`
	testing.expect_value(t, ctl_coord_refusal_cause(inactive), "chain not active (status completed)")
	generic := `{"v":1,"id":"r","ok":false,"error":{"code":"operation_conflict","message":"only a cancelled, done or merge-blocked ordinary task can be reopened"}}`
	testing.expect_value(t, ctl_coord_refusal_cause(generic), "")
}

// REQ T1-4: --assignee self.
@(test)
test_assignee_self_resolve :: proc(t: ^testing.T) {
	solo := `{"v":1,"id":"x","ok":true,"data":{"authority":{"kind":"owner","bridge_id":"br"},"caller":{"agent_id":"agt_coord","instance_id":"inst_c","coordinator":true,"worker_fleet_row":true}}}`
	r := ctl_assignee_self_resolve(solo)
	testing.expect_value(t, r.code, "")
	testing.expect_value(t, r.agent_id, "agt_coord")
	// Coordinator without a worker fleet row: not solo.
	not_solo := `{"ok":true,"data":{"authority":{"kind":"owner"},"caller":{"agent_id":"agt_coord","coordinator":true,"worker_fleet_row":false}}}`
	ns := ctl_assignee_self_resolve(not_solo)
	testing.expect_value(t, ns.code, "solo_required")
	testing.expect(t, strings.contains(ns.message, "solo mode") && strings.contains(ns.message, "task done --force"), ns.message)
	// Worker token (holds a fleet row, not the coordinator), reviewer token, and
	// a coordinator of another chain all read coordinator=false.
	worker := `{"ok":true,"data":{"authority":{"kind":"owner"},"caller":{"agent_id":"agt_worker","coordinator":false,"worker_fleet_row":true}}}`
	testing.expect_value(t, ctl_assignee_self_resolve(worker).code, "coordinator_only")
	reviewer := `{"ok":true,"data":{"authority":{"kind":"owner"},"caller":{"agent_id":"agt_reviewer","coordinator":false,"worker_fleet_row":false}}}`
	testing.expect_value(t, ctl_assignee_self_resolve(reviewer).code, "coordinator_only")
	// A legacy Hub chain: owner_chain_only.
	hub := `{"ok":true,"data":{"chain_id":"chain_h","coordinator_agent_instance_id":"inst_c"}}`
	testing.expect_value(t, ctl_assignee_self_resolve(hub).code, "owner_chain_only")
	// No caller block (older Bridge): unresolved, never guessed.
	testing.expect_value(t, ctl_assignee_self_resolve(`{"ok":true,"data":{"authority":{"kind":"owner"}}}`).code, "self_unresolved")
	// Arg substitution keeps every other flag.
	out := ctl_args_replace_value([]string{"ham-ctl", "task", "create", "--title", "t", "--assignee", "self", "--reviewer", "agt_r"}, "--assignee", "agt_coord")
	testing.expect_value(t, option_value(out, "--assignee", ""), "agt_coord")
	testing.expect_value(t, option_value(out, "--reviewer", ""), "agt_r")
	testing.expect(t, ctl_assignee_is_self([]string{"--assignee", "self"}) && !ctl_assignee_is_self([]string{"--assignee", "agt_x"}), "self detection")
}

// REQ T1-3 regression: `task-chain summary get|show` used to OVERWRITE the
// chain summary with the literal word. Only an explicit write writes.
@(test)
test_chain_summary_get_show_are_read_only :: proc(t: ^testing.T) {
	for sub in ([?]string{"get", "show"}) {
		mode, _ := ctl_v2_task_chain_summary_mode([]string{sub}, []string{"ham-ctl", "task-chain", "summary", sub})
		testing.expectf(t, mode == .Read, "summary %s reads", sub)
		_, writes := ctl_v2_task_chain_summary_params([]string{sub}, []string{"ham-ctl", "task-chain", "summary", sub})
		testing.expectf(t, !writes, "summary %s builds no write body", sub)
		with_chain, _ := ctl_v2_task_chain_summary_mode([]string{sub, "chain_1"}, []string{"ham-ctl", "task-chain", "summary", sub, "chain_1"})
		testing.expect(t, with_chain == .Read, "a chain id after get/show is still a read")
		testing.expect_value(t, ctl_v2_task_chain_summary_read_chain([]string{sub, "chain_1"}, nil), "chain_1")
	}
	bare, _ := ctl_v2_task_chain_summary_mode(nil, []string{"ham-ctl", "task-chain", "summary"})
	testing.expect(t, bare == .Read, "a bare summary reads")
	// An unknown word is refused, never stored as the summary.
	word, why := ctl_v2_task_chain_summary_mode([]string{"overview"}, []string{"ham-ctl", "task-chain", "summary", "overview"})
	testing.expect(t, word == .Invalid && strings.contains(why, "summary set"), why)
	_, stored := ctl_v2_task_chain_summary_params([]string{"overview"}, []string{"ham-ctl", "task-chain", "summary", "overview"})
	testing.expect(t, !stored, "an unknown word is not written")
	// get with write flags is refused.
	mixed, _ := ctl_v2_task_chain_summary_mode([]string{"get"}, []string{"ham-ctl", "task-chain", "summary", "get", "--body", "x"})
	testing.expect(t, mixed == .Invalid, "get never writes")
	// Writes: set <text>, set --file/--stdin, and flags without set.
	set, _ := ctl_v2_task_chain_summary_params([]string{"set", "Done."}, []string{"ham-ctl", "task-chain", "summary", "set", "Done."})
	testing.expect_value(t, set, `{"summary":"Done."}`)
	stdin, _ := ctl_v2_task_chain_summary_params([]string{"set"}, []string{"ham-ctl", "task-chain", "summary", "set", "--stdin"}, "From stdin.")
	testing.expect_value(t, stdin, `{"summary":"From stdin."}`)
	flag, _ := ctl_v2_task_chain_summary_params(nil, []string{"ham-ctl", "task-chain", "summary", "--body", "Via flag."})
	testing.expect_value(t, flag, `{"summary":"Via flag."}`)
	_, empty_set := ctl_v2_task_chain_summary_params([]string{"set"}, []string{"ham-ctl", "task-chain", "summary", "set"})
	testing.expect(t, !empty_set, "set without text is refused")
}

@(test)
test_coord_plan_cancel_dependents :: proc(t: ^testing.T) {
	repoint := ctl_coord_plan("cancel", "task_1", []string{"--reason", "x", "--dependents", "repoint", "--to", "task_2"})
	testing.expect_value(t, repoint.error, "")
	testing.expect(t, strings.contains(repoint.params, `"dependents":"repoint:task_2"`), repoint.params)
	inline := ctl_coord_plan("cancel", "task_1", []string{"--reason", "x", "--dependents", "repoint:task_3"})
	testing.expect(t, strings.contains(inline.params, `"dependents":"repoint:task_3"`), inline.params)
	drop := ctl_coord_plan("cancel", "task_1", []string{"--reason", "x", "--dependents", "drop"})
	testing.expect(t, strings.contains(drop.params, `"dependents":"drop"`), drop.params)
	testing.expect(t, ctl_coord_plan("cancel", "task_1", []string{"--reason", "x", "--dependents", "repoint"}).error != "", "repoint needs --to")
	testing.expect(t, ctl_coord_plan("cancel", "task_1", []string{"--reason", "x", "--dependents", "drop", "--to", "task_2"}).error != "", "--to only with repoint")
	testing.expect(t, ctl_coord_plan("cancel", "task_1", []string{"--reason", "x", "--dependents", "bogus"}).error != "", "bad mode")
	none := ctl_coord_plan("cancel", "task_1", []string{"--reason", "x"})
	testing.expect(t, !strings.contains(none.params, "dependents"), "default dependents left to the owner")
}

@(test)
test_coord_plan_revoke_flags :: proc(t: ^testing.T) {
	p := ctl_coord_plan("revoke", "task_1", []string{"--reason", "x", "--disable-fleet", "--stop"})
	testing.expect_value(t, p.error, "")
	testing.expect(t, strings.contains(p.params, `"disable_fleet":true`) && strings.contains(p.params, `"mode":"stop"`), p.params)
	testing.expect(t, ctl_coord_plan("revoke", "task_1", []string{"--reason", "x", "--stop", "--mode", "checkpoint"}).error != "", "stop vs checkpoint conflict")
	testing.expect(t, ctl_coord_plan("revoke", "task_1", []string{"--reason", "x", "--mode", "kill"}).error != "", "bad mode")
	plain := ctl_coord_plan("revoke", "task_1", []string{"--reason", "x"})
	testing.expect(t, !strings.contains(plain.params, "disable_fleet") && !strings.contains(plain.params, "mode"), plain.params)
}

@(test)
test_coord_plan_submit_done :: proc(t: ^testing.T) {
	s := ctl_coord_plan("submit-for-review", "task_1", []string{"--reason", "stalled", "--summary", "work done", "--override-ack"})
	testing.expect_value(t, s.error, "")
	testing.expect_value(t, s.method, "agent.task.submit_review")
	testing.expect(t, strings.contains(s.params, `"summary":"work done"`) && strings.contains(s.params, `"override_ack":true`), s.params)
	testing.expect(t, strings.contains(ctl_coord_plan("submit-for-review", "task_1", []string{"--reason", "x", "--summary", "s", "--head", "abc"}).error, "no --head"), "--head is refused")
	testing.expect(t, strings.contains(ctl_coord_plan("submit-for-review", "task_1", []string{"--reason", "x"}).error, "--summary"), "--summary required")
	d := ctl_coord_plan("done", "task_1", []string{"--force", "--reason", "docs only"})
	testing.expect_value(t, d.method, "agent.task.complete")
	testing.expect(t, strings.contains(d.params, `"force":true`), d.params)
	testing.expect(t, strings.contains(ctl_coord_plan("done", "task_1", []string{"--reason", "x"}).error, "--force"), "done needs --force")
}

@(test)
test_coord_plan_split :: proc(t: ^testing.T) {
	arr := ctl_coord_plan("split", "task_1", []string{"--reason", "big"}, `[{"title":"a"},{"title":"b","task_id":"task_b"}]`)
	testing.expect_value(t, arr.error, "")
	testing.expect_value(t, arr.method, "agent.task.split")
	testing.expect(t, strings.contains(arr.params, `"children":[{"title":"a"},{"title":"b","task_id":"task_b"}]`) && strings.contains(arr.params, `"dependents":"all"`), arr.params)
	obj := ctl_coord_plan("split", "task_1", []string{"--reason", "big"}, `{"children":[{"title":"a"}],"dependents":"map","map":{"task_dep":["task_a"]}}`)
	testing.expect_value(t, obj.error, "")
	testing.expect(t, strings.contains(obj.params, `"dependents":"map"`) && strings.contains(obj.params, `"map":{"task_dep":["task_a"]}`), obj.params)
	flag_map := ctl_coord_plan("split", "task_1", []string{"--reason", "big", "--dependents", "map"}, `[{"title":"a"}]`, `{"task_dep":["task_a"]}`)
	testing.expect(t, strings.contains(flag_map.params, `"map":{"task_dep":["task_a"]}`), flag_map.params)
	testing.expect(t, ctl_coord_plan("split", "task_1", []string{"--reason", "big", "--dependents", "map"}, `[{"title":"a"}]`).error != "", "map mode needs a map")
	testing.expect(t, ctl_coord_plan("split", "task_1", []string{"--reason", "big", "--dependents", "last"}, `[{"title":"a"}]`, `{"x":["y"]}`).error != "", "--map only with map")
	testing.expect(t, ctl_coord_plan("split", "task_1", []string{"--reason", "big"}, `[]`).error != "", "at least one child")
	testing.expect(t, ctl_coord_plan("split", "task_1", []string{"--reason", "big"}).error != "", "--child-file required")
	testing.expect(t, ctl_coord_plan("split", "task_1", []string{"--reason", "big", "--dependents", "some"}, `[{"title":"a"}]`).error != "", "bad dependents")
}

@(test)
test_coord_plan_review_roles :: proc(t: ^testing.T) {
	p := ctl_coord_plan("review-roles", "task_1", []string{"--role", "reviewer=agt_r", "--role", "security=agt_s@inst_s", "--require-user-approval"})
	testing.expect_value(t, p.error, "")
	testing.expect_value(t, p.method, "agent.task.review_roles")
	testing.expect(t, strings.contains(p.params, `"pairs":[{"role":"reviewer","agent_id":"agt_r"},{"role":"security","agent_id":"agt_s","instance_id":"inst_s"}]`), p.params)
	testing.expect(t, strings.contains(p.params, `"requires_user_approval":true`), p.params)
	testing.expect(t, ctl_coord_plan("review-roles", "task_1", nil).error != "", "a pair is required")
	testing.expect(t, ctl_coord_plan("review-roles", "task_1", []string{"--role", "reviewer"}).error != "", "role=agent shape")
	off := ctl_coord_plan("review-roles", "task_1", []string{"--role", "reviewer=agt_r", "--no-require-user-approval"})
	testing.expect(t, strings.contains(off.params, `"requires_user_approval":false`), "removal is sent; the owner refuses it for agents")
}

@(test)
test_coord_owner_only_detection :: proc(t: ^testing.T) {
	testing.expect(t, ctl_coord_owner_only(`{"v":1,"id":"r","ok":false,"error":{"code":"bad_request","message":"owner_chain_only: this coordinator control is served only for chains owned by this Bridge"}}`), "typed error detected")
	testing.expect(t, !ctl_coord_owner_only(`{"ok":false,"error":{"code":"invalid_scope","message":"refused: only the verified chain coordinator may use this control"}}`), "a refusal is not owner_chain_only")
	testing.expect(t, ctl_coord_task_verb("split") && ctl_coord_task_verb("submit-for-review") && !ctl_coord_task_verb("hold"), "task verb set")
	testing.expect(t, !ctl_coord_owner_only(`{"ok":false,"error":{"code":"hub_error","message":"chain must be active"}}`), "a Hub refusal is not owner_chain_only")
	// Success replies that merely contain the text are never owner_chain_only.
	testing.expect(t, !ctl_coord_owner_only(`{"v":1,"id":"r","ok":true,"data":{"task_id":"t","title":"owner_chain_only docs"}}`), "success mentioning the word")
	testing.expect(t, !ctl_coord_owner_only(`{"ok":false,"error":{"code":"operation_conflict","message":"cannot split: see owner_chain_only notes"}}`), "the word mid-message is not the typed error")
	testing.expect(t, ctl_coord_owner_only(`{"ok":false,"error":{"code":"owner_chain_only","message":"x"}}`), "typed by code")
	testing.expect(t, !ctl_coord_owner_only(`not json owner_chain_only`), "unparsable reply")
}

// Review fix: `task-chain summary get` on a Bridge-owned chain reads the owner
// store's curated summary from agent.task_chain.show, never the Hub.
@(test)
test_owner_summary_view_reads_owner_show :: proc(t: ^testing.T) {
	show := `{"v":1,"id":"x","ok":true,"data":{"chain_id":"chain_o","authority":{"kind":"owner","bridge_id":"br"},"summary":"# Owner summary\nline 2","summary_version":"7","items":[]}}`
	view, is_owner := ctl_owner_summary_view(show)
	testing.expect(t, is_owner, "owner chain")
	testing.expect_value(t, view, `{"ok":true,"data":{"chain_id":"chain_o","summary":"# Owner summary\nline 2","version":"7","authority":"owner"}}`)
	empty, empty_owner := ctl_owner_summary_view(`{"ok":true,"data":{"chain_id":"chain_o","authority":{"kind":"owner"}}}`)
	testing.expect(t, empty_owner && strings.contains(empty, `"summary":""`) && strings.contains(empty, `"version":"0"`), empty)
	// Ciphertext the owner Bridge could not decrypt is refused as vault_locked.
	locked, locked_owner := ctl_owner_summary_view(`{"ok":true,"data":{"chain_id":"chain_o","authority":{"kind":"owner"},"summary":"vault:v2:abc","summary_version":"3"}}`)
	testing.expect(t, locked_owner && strings.contains(locked, `"ok":false`) && strings.contains(locked, `"code":"vault_locked"`) && !strings.contains(locked, "vault:v2:abc"), locked)
	// A non-owner chain and a failed show are not owner views (the caller errors;
	// Hub chains are removed, so there is no Hub read).
	_, hub := ctl_owner_summary_view(`{"ok":true,"data":{"chain_id":"chain_h","coordinator_agent_instance_id":"inst"}}`)
	testing.expect(t, !hub, "hub chain")
	_, failed := ctl_owner_summary_view(`{"ok":false,"error":{"code":"invalid_scope","message":"owner chain read refused"}}`)
	testing.expect(t, !failed, "failed show")
}
