package main

import "core:strings"
import "core:sync"
import "core:testing"
import httpc "odin_test:lib/httpc"

// relay_failure_test_seen_stall_ms records the stall guard the relay handed to
// the transport; relay_failure_test_error is the transport outcome to fake.
@(private = "file")
relay_failure_test_seen_stall_ms: int
@(private = "file")
relay_failure_test_error: httpc.Error
@(private = "file")
relay_failure_test_mutex: sync.Mutex

@(private = "file")
relay_failure_test_fetch :: proc(req: httpc.Request) -> (httpc.Response, httpc.Error) {
	relay_failure_test_seen_stall_ms = req.stall_timeout_ms
	return {}, relay_failure_test_error
}

// REQ-EVQ-2: the events long poll gets a stall guard above its largest wait
// (30 s) plus margin; every other relayed method keeps the 20 s default.
@(test)
relay_stall_budget_is_scoped_to_the_events_long_poll :: proc(t: ^testing.T) {
	testing.expect(t, bridge_agent_relay_stall_ms("agent.events.next") >= 30_000 + 10_000, "long poll needs 30 s plus margin")
	for method in ([]string{"agent.events.ack", "agent.chat.send", "agent.lease.next", "agent.search", ""}) {
		testing.expect_value(t, bridge_agent_relay_stall_ms(method), httpc.DEFAULT_STALL_TIMEOUT_MS)
	}
}

// REQ-EVQ-3: a relay with no HTTP response names its transport cause, and the
// envelope relay hands the per-method stall guard to the transport.
@(test)
relay_failure_names_the_transport_cause :: proc(t: ^testing.T) {
	sync.mutex_lock(&relay_failure_test_mutex)
	defer sync.mutex_unlock(&relay_failure_test_mutex)
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_relay_test", instance_token = "tok"}
	cases := []struct {
		err:  httpc.Error,
		want: string,
	}{
		{.Timeout, "Hub relay failed: timed out"},
		{.Connect, "Hub relay failed: connect failed"},
		{.Recv, "Hub relay failed: receive failed"},
	}
	for c in cases {
		relay_failure_test_error = c.err
		relay_failure_test_seen_stall_ms = 0
		relay := bridge_local_relay_agent_envelope_via(
			{"api", "v1", "agent-actions", "events", "next"},
			"agent.events.next",
			`{"wait_ms":30000,"limit":1}`,
			rec,
			httpc.LONG_TRANSFER_TIMEOUT_MS,
			relay_failure_test_fetch,
		)
		defer delete(relay.body)
		testing.expect(t, !relay.ok)
		testing.expect_value(t, relay.err, c.err)
		testing.expect_value(t, relay_failure_test_seen_stall_ms, BRIDGE_EVENTS_LONG_POLL_STALL_MS)
		other := bridge_local_relay_agent_envelope_via({"api", "v1", "agent-actions", "events", "ack"}, "agent.events.ack", `{}`, rec, httpc.LONG_TRANSFER_TIMEOUT_MS, relay_failure_test_fetch)
		delete(other.body)
		testing.expect_value(t, relay_failure_test_seen_stall_ms, httpc.DEFAULT_STALL_TIMEOUT_MS)
		response := bridge_local_relay_failure("req_1", "Hub relay failed", relay)
		defer delete(response)
		testing.expectf(t, strings.contains(response, c.want), "response %q lacks %q", response, c.want)
		testing.expect(t, strings.contains(response, `"code":"retryable_unavailable"`), "code is unchanged")
	}
	// A request refused locally (never sent) says so instead of a transport cause.
	local := bridge_local_relay_failure("req_2", "Hub REST relay failed", Bridge_Local_Relay_Result{})
	defer delete(local)
	testing.expect(t, strings.contains(local, "Hub REST relay failed: request was not sent"), local)
}
