package main

import "core:strings"
import "core:testing"
import "core:time"
import "core:thread"
import "core:sync"

// Drives the real agent-method dispatch (bridge_local_handle_agent_method) end to
// end: a blocking agent.permission.request handled on one thread is resolved by an
// agent.permission.reply on another, exactly as the bridge local endpoint dispatches
// JSONL lines from the extension/wrapper.

Perm_Integ_Result :: struct {
	response: string,
	done: bool,
	mu: sync.Mutex,
}

@(test)
bridge_permission_request_reply_roundtrip_via_handler :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_integ", role = .Agent}

	shared := new(Perm_Integ_Result)
	defer free(shared)

	Ctx :: struct { rec: Bridge_Local_Agent_Token_Record, shared: ^Perm_Integ_Result }
	c := new(Ctx)
	defer free(c)
	c.rec = rec
	c.shared = shared

	// Fire the blocking request handler on a worker thread.
	worker_thread := thread.create_and_start_with_data(rawptr(c), proc(data: rawptr) {
		cc := (^Ctx)(data)
		params := "{\"request_id\":\"rq_integ_roundtrip\",\"tool\":\"bash\",\"risk\":\"risky\",\"input\":{\"cmd\":\"rm -rf x\"},\"timeout_ms\":5000}"
		resp := bridge_local_handle_agent_method("id-req", "agent.permission.request", params, cc.rec)
		sync.mutex_lock(&cc.shared.mu)
		cc.shared.response = strings.clone(resp)
		cc.shared.done = true
		sync.mutex_unlock(&cc.shared.mu)
	})

	// Wait for the request to be registered as pending.
	registered := false
	for i in 0..<200 {
		if bridge_permission_test_is_pending("inst_integ", "rq_integ_roundtrip") { registered = true; break }
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, registered)

	// Resolve it via the reply handler, as a local UI/wrapper would.
	reply_params := "{\"request_id\":\"rq_integ_roundtrip\",\"decision\":\"allow\",\"reason\":\"approved in test\"}"
	reply_resp := bridge_local_handle_agent_method("id-reply", "agent.permission.reply", reply_params, rec)
	testing.expect(t, strings.contains(reply_resp, "\"accepted\":true"))

	// The blocking request handler should now return an allow decision.
	got := false
	response := ""
	for i in 0..<400 {
		sync.mutex_lock(&shared.mu)
		if shared.done { response = shared.response; got = true }
		sync.mutex_unlock(&shared.mu)
		if got do break
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, got)
	testing.expect(t, strings.contains(response, "\"decision\":\"allow\""))
	testing.expect(t, strings.contains(response, "\"reason\":\"approved in test\""))
	testing.expect(t, strings.contains(response, "\"request_id\":\"rq_integ_roundtrip\""))

	thread.join(worker_thread)
	thread.destroy(worker_thread)
}

@(test)
bridge_permission_reply_unknown_request_not_accepted :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_permission_test_mutex)
	defer sync.mutex_unlock(&bridge_permission_test_mutex)
	bridge_permission_test_reset()
	defer bridge_permission_test_reset()

	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_integ2", role = .Agent}
	resp := bridge_local_handle_agent_method("id-x", "agent.permission.reply", "{\"request_id\":\"nope\",\"decision\":\"allow\"}", rec)
	testing.expect(t, strings.contains(resp, "\"accepted\":false"))
}
