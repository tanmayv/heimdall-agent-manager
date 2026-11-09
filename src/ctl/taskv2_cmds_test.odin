package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// Task System v2 (M2) ctl surface: the brief param builder behind
// `task create/update` and the per-task rendering of a publish 422
// brief_incomplete (both envelopes). Pure procs, no bridge/hub involved.

@(test)
test_task_brief_json_from_flags :: proc(t: ^testing.T) {
	args := []string{
		"ham-ctl", "task", "create", "--title", "x",
		"--goal", "Retry transient 5xx",
		"--acceptance", "retries 3x, with backoff", // comma kept: acceptance is prose
		"--acceptance", "unit test covers 503",
		"--input", "#evt_1,facet:t1:1:handoff",
		"--review-role", "reviewer", "--review-role", "security",
	}
	brief, ok := ctl_task_brief_json(args, "")
	defer delete(brief)
	testing.expect(t, ok, "brief present")
	testing.expect_value(t, brief, `{"goal":"Retry transient 5xx","acceptance":["retries 3x, with backoff","unit test covers 503"],"inputs":["#evt_1","facet:t1:1:handoff"],"review_roles":["reviewer","security"]}`)
}

@(test)
test_task_brief_json_file_base_flags_override :: proc(t: ^testing.T) {
	file := `{"goal":"from file","acceptance":["a1","a2"],"inputs":["#e9"],"review_roles":["reviewer"],"assignee":"agt_w","budget":{"max_attempts":3},"output":{"schema":"x"},"unknown":1}`
	// no flags: the whole file is carried; the unknown key is forwarded so the
	// hub rejects it (unknown_brief_fields) instead of ham-ctl dropping it.
	base, ok := ctl_task_brief_json([]string{"ham-ctl"}, file)
	defer delete(base)
	testing.expect(t, ok, "file alone is a brief")
	testing.expect_value(t, base, `{"goal":"from file","acceptance":["a1","a2"],"inputs":["#e9"],"review_roles":["reviewer"],"assignee":"agt_w","budget":{"max_attempts":3},"output":{"schema":"x"},"unknown":1}`)

	// reviewers and explicit nulls from the file survive; --clear-<field> sends null.
	rev, rok := ctl_task_brief_json([]string{"ham-ctl", "--clear-review-roles"}, `{"reviewers":["agt_r"],"budget":null}`)
	defer delete(rev)
	testing.expect(t, rok, "reviewers file is a brief")
	testing.expect_value(t, rev, `{"review_roles":null,"reviewers":["agt_r"],"budget":null}`)

	// flags override field by field; untouched file fields survive
	over, ok2 := ctl_task_brief_json([]string{"ham-ctl", "--goal", "from flag", "--acceptance", "only this"}, file)
	defer delete(over)
	testing.expect(t, ok2, "brief present")
	testing.expect(t, strings.has_prefix(over, `{"goal":"from flag","acceptance":["only this"],"inputs":["#e9"],`), "flags win, file fills the rest")
	testing.expect(t, strings.contains(over, `"review_roles":["reviewer"]`), "file review_roles kept")
}

@(test)
test_task_brief_json_absent :: proc(t: ^testing.T) {
	_, ok := ctl_task_brief_json([]string{"ham-ctl", "task", "update", "t1", "--title", "only title"}, "")
	testing.expect(t, !ok, "no brief flags, no file -> no brief")
	testing.expect(t, !ctl_task_brief_flags_present([]string{"--title", "x", "--priority", "p1"}), "no brief flags")
	testing.expect(t, ctl_task_brief_flags_present([]string{"--goal", "g"}), "goal is a brief flag")
	testing.expect(t, !ctl_task_brief_flags_present([]string{"--verify", "make"}), "verify is no longer a brief flag")
}

// REQ-TV2-4: `--replace-brief` with an explicitly empty `{}` file replaces the
// brief with {}; a verify-only file stays the compatibility no-op.
@(test)
test_task_brief_replace_with_empty_file :: proc(t: ^testing.T) {
	empty, ok := ctl_task_brief_json([]string{"ham-ctl"}, "  {}\n")
	defer delete(empty)
	testing.expect(t, ok, "an explicit {} file is a brief")
	testing.expect_value(t, empty, "{}")
	_, verify_only := ctl_task_brief_json([]string{"ham-ctl"}, `{"verify":"make"}`)
	testing.expect(t, !verify_only, "a verify-only file carries no brief")

	tmp, _ := os.temp_dir(context.temp_allocator)
	path := strings.concatenate({tmp, "/ham_ctl_replace_empty_brief_test.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)string("{}")) == nil, "write brief file")
	defer os.remove(path)
	field, fok := ctl_task_brief_field([]string{"ham-ctl", "task", "update", "t1", "--brief-file", path, "--replace-brief"})
	testing.expect(t, fok, "replace with {} sends a brief")
	testing.expect_value(t, field, `"brief":{},"replace_brief":true`)

	vpath := strings.concatenate({tmp, "/ham_ctl_replace_verify_only_brief_test.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(vpath, transmute([]byte)string(`{"verify":"make"}`)) == nil, "write verify-only file")
	defer os.remove(vpath)
	_, vok := ctl_task_brief_field([]string{"ham-ctl", "task", "update", "t1", "--brief-file", vpath, "--replace-brief"})
	testing.expect(t, !vok, "verify-only replace stays a no-op")
}

@(test)
test_brief_incomplete_render_agent_envelope :: proc(t: ^testing.T) {
	// Agent mode: the bridge wraps the hub's 422 body as a JSON string in error.message.
	hub := `{"error":{"code":"validation_failed","message":"brief incomplete: ...","details":{"code":"brief_incomplete","tasks":[{"task_id":"task_a","missing":["goal","verify"]},{"task_id":"task_b","missing":["review_role:security"]}]}},"meta":{"request_id":"r1"}}`
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"v":1,"id":"ham-ctl-agent","ok":false,"error":{"code":"hub_error","message":"`)
	json_write_string(&b, hub)
	strings.write_string(&b, `"}}`)
	text, found := ctl_brief_incomplete_render(strings.to_string(b))
	defer delete(text)
	testing.expect(t, found, "brief_incomplete detected through the bridge envelope")
	testing.expect(t, strings.contains(text, "task_a: missing goal, verify\n"), "per-task line a")
	testing.expect(t, strings.contains(text, "task_b: missing review_role:security\n"), "per-task line b")
	testing.expect(t, strings.has_prefix(text, "publish refused: brief incomplete\n"), "header")
}

@(test)
test_brief_incomplete_render_user_envelope_and_negative :: proc(t: ^testing.T) {
	// User mode: the hub body IS the response.
	hub := `{"error":{"code":"validation_failed","message":"brief incomplete","details":{"code":"brief_incomplete","tasks":[{"task_id":"task_z","missing":["acceptance"]}]}},"meta":{}}`
	text, found := ctl_brief_incomplete_render(hub)
	defer delete(text)
	testing.expect(t, found, "detected in the plain hub envelope")
	testing.expect(t, strings.contains(text, "task_z: missing acceptance\n"), "rendered")

	_, other := ctl_brief_incomplete_render(`{"error":{"code":"validation_failed","message":"x","details":{"code":"other"}}}`)
	testing.expect(t, !other, "a different 422 is not rendered as brief_incomplete")
	_, success := ctl_brief_incomplete_render(`{"v":1,"ok":true,"data":{"data":{"chain_id":"c1","publish_state":"published"}}}`)
	testing.expect(t, !success, "success is untouched")
}

@(test)
test_lease_peek_parse :: proc(t: ^testing.T) {
	resp := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"data":{"status":"current","lease":{"lease_id":"lse_1","task_id":"task_1","attempt_no":2},"task":{"task_id":"task_1","brief":{"goal":"g"}},"pack":{"placement":{"directory_path":"/repo","workdir":"/repo/.heimdall/worktrees/task_1"}}}}}`
	lease, ok := ctl_lease_peek_parse(resp)
	testing.expect(t, ok, "lease parsed")
	testing.expect_value(t, lease.status, "current")
	testing.expect_value(t, lease.lease_id, "lse_1")
	testing.expect_value(t, lease.task_id, "task_1")
	testing.expect_value(t, lease.attempt_no, 2)
	testing.expect_value(t, lease.directory_path, "/repo/.heimdall/worktrees/task_1")

	on_lease, ok2 := ctl_lease_peek_parse(`{"data":{"status":"current","lease":{"task_id":"t2","placement":{"directory_path":"/d"}},"pack":{"placement":{"directory_path":"/other"}}}}`)
	testing.expect(t, ok2, "lease parsed")
	testing.expect_value(t, on_lease.directory_path, "/d")

	_, none := ctl_lease_peek_parse(`{"data":{"status":"none"}}`)
	testing.expect(t, !none, "no lease -> not parsed")
}

@(test)
test_command_tokens_skips_v2_flag_values :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "review", "post", "--verdict", "approve", "--findings-file", "f.json", "--on-behalf-of", "user"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)
	if len(tokens) == 2 {
		testing.expect_value(t, tokens[0], "review")
		testing.expect_value(t, tokens[1], "post")
	}
}

// The handoff flags take values: `lease switch --dead-end x task_b` must keep
// task_b as the positional, not x.
@(test)
test_command_tokens_skips_handoff_flag_values :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "lease", "switch", "--dead-end", "tried x", "--next-steps", "do y", "--decision", "z", "task_b", "--summary", "s"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 3)
	if len(tokens) == 3 do testing.expect_value(t, tokens[2], "task_b")
}

// REQ-MW-5/9: cancel always identifies an execution; delayed commands cannot
// silently retarget whichever generation happens to be current.
@(test)
test_workflow_cancel_params_require_execution :: proc(t: ^testing.T) {
 tokens := []string{"cancel","wrun_1"}
 missing, _ := ctl_v2_workflow_cancel_params(tokens,nil)
 testing.expect_value(t,missing,"")
 id, params := ctl_v2_workflow_cancel_params(tokens,[]string{"--execution","2","--reason","stop"})
 defer delete(params)
 testing.expect_value(t,id,"wrun_1")
 testing.expect(t,strings.contains(params,`"execution_no":2`),"execution is carried through the transport")
}

@(test)
test_live_requirements_ctl_context_flags :: proc(t: ^testing.T) {
    args := []string{"ham-ctl","review","post","--requirements-revision","7","--expected-attempt","2","--expected-head","abc","--lease","lease_a","--verdict","approve","task_a"};
    tokens := command_tokens(args)
    defer delete(tokens)
    testing.expect_value(t,len(tokens),3)
    if len(tokens)==3 do testing.expect_value(t,tokens[2],"task_a")
    review,ok := ctl_v2_review_post_params(tokens[1:],args,"")
    defer delete(review)
    testing.expect(t,ok && strings.contains(review,`"requirements_revision":7`) && strings.contains(review,`"expected_attempt_no":2`) && strings.contains(review,`"expected_head":"abc"`) && strings.contains(review,`"lease_id":"lease_a"`))
    heartbeat := ctl_v2_heartbeat_params([]string{"--lease","lease_a","--acknowledge-requirements-revision","7"})
    testing.expect(t,strings.contains(heartbeat,`"acknowledge_requirements_revision":7`))
    submit,sok := ctl_v2_lease_submit_params([]string{"--summary","done","--lease","lease_a","--requirements-revision","7"},"","","","/work")
    defer delete(submit)
    testing.expect(t,sok && strings.contains(submit,`"requirements_revision":7`) && strings.contains(submit,`"lease_id":"lease_a"`))
    update := ctl_agentmode_task_update_params("task_a",with_kr([]string{"--goal","new objective","--acceptance","new acceptance","--reason","scope changed","--expected-requirements-revision","7"}))
    testing.expect(t,!strings.contains(update,"new objective") && !strings.contains(update,"scope changed") && strings.contains(update,`"expected_requirements_revision":7`))
    opened := unseal_out(update)
    testing.expect(t,strings.contains(opened,"new objective") && strings.contains(opened,"new acceptance") && strings.contains(opened,"scope changed"))
    token,_:=ctl_vault_seal("prior objective",tkr(CTL_TEST_WRITE_KEY),context.temp_allocator)
    history:=unseal_out(json_object_from_slice([]string{json_kv("history",strings.concatenate({"Before: ",token,"\nAfter: ",token},context.temp_allocator))}))
    testing.expect(t,strings.contains(history,"Before: prior objective") && !strings.contains(history,"vault:v2:"))

}

// R4a: an owner-chain `lease next` (served by the owner Bridge store, see
// src/bridge/owner_agent_routing.odin Owner_Agent_Next) keeps the Hub shape the
// lease verbs read: lease_id/task_id and the per-task worktree as placement.
@(test)
test_lease_peek_parse_owner_chain_shape :: proc(t: ^testing.T) {
	resp := `{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"status":"granted","lease":{"lease_id":"lease_ab","task_id":"task_ab","chain_id":"chain_ab","requirements_revision":"2","acknowledged":"0","placement":{"workdir":"/repo/.heimdall/worktrees/task_ab","directory_path":"/repo","branch":"heimdall/task_ab"}},"task":{"task_id":"task_ab","chain_id":"chain_ab"},"authority":{"kind":"owner","bridge_id":"brg_owner"}}}`
	lease, ok := ctl_lease_peek_parse(resp)
	testing.expect(t, ok, "owner lease parsed")
	testing.expect_value(t, lease.status, "granted")
	testing.expect_value(t, lease.lease_id, "lease_ab")
	testing.expect_value(t, lease.task_id, "task_ab")
	testing.expect_value(t, lease.directory_path, "/repo/.heimdall/worktrees/task_ab")
	_, none := ctl_lease_peek_parse(`{"v":1,"ok":true,"data":{"status":"none","authority":{"kind":"owner","bridge_id":"brg_owner"}}}`)
	testing.expect(t, !none, "no owner lease -> not parsed")
}
