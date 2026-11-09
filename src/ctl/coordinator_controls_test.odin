package main

import "core:strings"
import "core:testing"

@(test)
test_coord_plan_methods_and_reasons :: proc(t: ^testing.T) {
	cases := [?]struct{ verb, method, fallback: string }{
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
		testing.expect_value(t, plan.hub_fallback, c.fallback)
		testing.expectf(t, strings.contains(plan.params, `"task_id":"task_1"`) && strings.contains(plan.params, `"reason":"why"`), "%s params %s", c.verb, plan.params)
	}
	// Verbs whose owner method requires a reason refuse before sending anything.
	for verb in ([?]string{"hold", "cancel", "reopen", "delete", "escalate", "merge-retry", "revoke", "done", "split", "submit-for-review"}) {
		plan := ctl_coord_plan(verb, "task_1", []string{"--force", "--summary", "s"}, `[{"title":"a"}]`)
		testing.expectf(t, strings.contains(plan.error, "--reason"), "%s without --reason: %q", verb, plan.error)
	}
	// release / recheck stay optional (the Hub accepts them without a reason).
	testing.expect_value(t, ctl_coord_plan("release", "task_1", nil).error, "")
	testing.expect_value(t, ctl_coord_plan("recheck", "task_1", nil).error, "")
	// unblock accepts --note as its reason.
	unblock := ctl_coord_plan("unblock", "task_1", []string{"--note", "fixed placement"})
	testing.expect(t, strings.contains(unblock.params, `"reason":"fixed placement"`), "unblock --note is the reason")
	testing.expect(t, ctl_coord_plan("cancel", "", []string{"--reason", "x"}).error != "", "task id required")
	chain := ctl_coord_plan("hold", "task_1", []string{"--reason", "x", "--chain", "chain_1"})
	testing.expect(t, strings.contains(chain.params, `"chain_id":"chain_1"`), "--chain forwarded")
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
}
