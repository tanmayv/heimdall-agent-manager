package agent

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Per-instance PTY/ACP transport through reconfiguration (agent settings panel
// T1): an explicit runtime_transport is validated like a launch, frozen in the
// destination snapshot, part of idempotency, committed by the move trigger and
// wins over the bridge-wide provider setting on every later launch.

@(private = "file")
TRANSPORT_ADAPTER_READY :: `{"installed":true,"state":"ready","version":"0.162.0","runtime_kind":"system","checked_at":"now"}`

@(private = "file")
transport_test_ready :: proc(t: ^testing.T, h: ^Start_Test, features: string, adapter_json: string) {
	start_test_sql(t, h, strings.concatenate({`UPDATE bridges SET capabilities_json='{"features":[`, features, `]}'; UPDATE agent_instances SET runtime_status='running', startup_status='ready';`}, context.temp_allocator))
	_, err := iface.bridge_provider_status_upsert(&h.pr, {bridge_id = "brg", provider = "codex", binary_path = "/bin/codex", state = "present", checked_at = START_TEST_NOW, acp_adapter_json = adapter_json})
	testing.expect_value(t, err.code, domain.Error_Code.None)
}

@(private = "file")
transport_test_second_id :: proc(_: rawptr, prefix: string) -> string { return fmt.tprintf("%ssecond", prefix) }

@(private = "file")
transport_test_input :: proc(key, transport: string, revision := 0) -> Reconfigure_Operation_Input {
	return {bridge_id = "brg", provider = "codex", provider_profile = "codex", model = "gpt-6.1-sol", idempotency_key = key, expected_revision = revision, runtime_transport = transport}
}

// Drives an accepted (Stopping) operation through the real stop confirmation and
// destination commit path, then returns the committed instance row.
@(private = "file")
transport_test_commit :: proc(t: ^testing.T, h: ^Start_Test, op: domain.Instance_Reconfiguration) -> domain.Agent_Instance {
	testing.expect_value(t, op.phase, domain.Instance_Reconfiguration_Phase.Stopping)
	stopped, ok, err := reconfiguration_advance(&h.service, op, .Source_Stopped, true, false)
	if !testing.expect(t, ok, err.message) do return {}
	reconfiguration_launch_destination(&h.service, stopped)
	stored, found, read_err := iface.instance_reconfiguration_get(&h.ar, "owner", "inst", op.idempotency_key)
	testing.expect(t, found, read_err.message)
	testing.expectf(t, stored.destination_committed, "destination committed (phase %v, %s)", stored.phase, stored.failure_message)
	// Settle the operation so later launches are not fenced by it.
	_, ready, ready_err := reconfiguration_advance(&h.service, stored, .Ready, true, true)
	testing.expect(t, ready, ready_err.message)
	return start_test_row(t, h)
}

transport_pty_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	// Bridge-wide setting says ACP and ACP is ready; the instance pins PTY.
	transport_test_ready(t, h, `"instance_reconfiguration_v1","acp_runtime_v1"`, TRANSPORT_ADAPTER_READY)
	start_test_sql(t, h, "UPDATE bridge_provider_settings SET transport='acp';")
	op, accepted, err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("pin-pty", "pty"))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect_value(t, op.source.runtime_transport, "pty")
	testing.expect_value(t, op.source.runtime_transport_override, "")
	testing.expect_value(t, op.destination.runtime_transport, "pty")
	testing.expect_value(t, op.destination.runtime_transport_override, "pty")
	row := transport_test_commit(t, h, op)
	testing.expect_value(t, row.runtime_transport, "pty")
	testing.expect_value(t, row.runtime_transport_override, "pty")
	// Relaunch: the instance choice wins over the bridge-provider ACP setting.
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='stopped', startup_status='stopped', stopped_by='user';")
	ticket, start_err := start_begin(&h.service, start_test_auth(), "inst", {ref = "after-pin", if_live = .Relaunch})
	testing.expect_value(t, start_err.code, domain.Error_Code.None)
	testing.expect_value(t, ticket.instance.runtime_transport, "pty")
	start_ticket_destroy(&ticket)
}

transport_acp_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	// No bridge-wide setting (catalog default PTY); the instance pins ACP.
	transport_test_ready(t, h, `"instance_reconfiguration_v1","acp_runtime_v1"`, TRANSPORT_ADAPTER_READY)
	op, accepted, err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("pin-acp", "acp"))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect_value(t, op.destination.runtime_transport, "acp")
	testing.expect_value(t, op.destination.runtime_transport_override, "acp")
	row := transport_test_commit(t, h, op)
	testing.expect_value(t, row.runtime_transport, "acp")
	testing.expect_value(t, row.runtime_transport_override, "acp")
	// The launch frame sent after commit carries the frozen ACP transport.
	last := h.commands[len(h.commands) - 1]
	testing.expect(t, strings.contains(last, `"effective_transport":"acp"`), last)
	// Relaunch with the bridge-wide setting explicitly PTY: ACP survives.
	start_test_sql(t, h, "UPDATE bridge_provider_settings SET transport='pty'; UPDATE agent_instances SET runtime_status='stopped', startup_status='stopped', stopped_by='user';")
	ticket, start_err := start_begin(&h.service, start_test_auth(), "inst", {ref = "after-acp", if_live = .Relaunch})
	testing.expect_value(t, start_err.code, domain.Error_Code.None)
	testing.expect_value(t, ticket.instance.runtime_transport, "acp")
	start_ticket_destroy(&ticket)
	// A later change that omits runtime_transport keeps the instance's choice.
	start_test_sql(t, h, "UPDATE agent_instances SET runtime_status='running', startup_status='ready';")
	row = start_test_row(t, h)
	// The harness generator is fixed; give the second operation distinct ids.
	h.ids.generate = transport_test_second_id
	kept, kept_ok, kept_err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("keep", "", row.configuration_revision))
	if !testing.expect(t, kept_ok, kept_err.message) do return
	testing.expect_value(t, kept.destination.runtime_transport, "acp")
	testing.expect_value(t, kept.destination.runtime_transport_override, "acp")
}

transport_omitted_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	// Omitted: unchanged derivation from the bridge-provider setting, no pin.
	transport_test_ready(t, h, `"instance_reconfiguration_v1","acp_runtime_v1"`, TRANSPORT_ADAPTER_READY)
	start_test_sql(t, h, "UPDATE bridge_provider_settings SET transport='acp';")
	op, accepted, err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("omitted", ""))
	if !testing.expect(t, accepted, err.message) do return
	testing.expect_value(t, op.destination.runtime_transport, "acp")
	testing.expect_value(t, op.destination.runtime_transport_override, "")
	row := transport_test_commit(t, h, op)
	testing.expect_value(t, row.runtime_transport, "acp")
	testing.expect_value(t, row.runtime_transport_override, "")
	// Unpinned instances keep following the bridge-wide setting on relaunch.
	start_test_sql(t, h, "UPDATE bridge_provider_settings SET transport=NULL; UPDATE agent_instances SET runtime_status='stopped', startup_status='stopped', stopped_by='user';")
	ticket, start_err := start_begin(&h.service, start_test_auth(), "inst", {ref = "unpinned", if_live = .Relaunch})
	testing.expect_value(t, start_err.code, domain.Error_Code.None)
	testing.expect_value(t, ticket.instance.runtime_transport, "pty")
	start_ticket_destroy(&ticket)
}

transport_refusals_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	Case :: struct {features, adapter, requested: string, want: domain.Error_Code, state: string}
	cases := []Case{
		{`"instance_reconfiguration_v1"`, TRANSPORT_ADAPTER_READY, "acp", .ACP_Unavailable, "unsupported_bridge"},
		{`"instance_reconfiguration_v1","acp_runtime_v1"`, `{"installed":false,"state":"missing","checked_at":"now"}`, "acp", .ACP_Unavailable, "missing"},
		{`"instance_reconfiguration_v1","acp_runtime_v1"`, `{"installed":false,"state":"installing","checked_at":"now"}`, "acp", .ACP_Installing, ""},
		{`"instance_reconfiguration_v1","acp_runtime_v1"`, TRANSPORT_ADAPTER_READY, "ssh", .Invalid_Transport, ""},
		{`"instance_reconfiguration_v1","acp_runtime_v1"`, TRANSPORT_ADAPTER_READY, "ACP", .Invalid_Transport, ""},
	}
	for c, i in cases {
		transport_test_ready(t, h, c.features, c.adapter)
		before := start_test_row(t, h)
		commands := len(h.commands)
		_, accepted, err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("refused", c.requested))
		testing.expectf(t, !accepted, "case %d must be refused", i)
		testing.expectf(t, err.code == c.want, "case %d got %v want %v: %s", i, err.code, c.want, err.message)
		if c.state != "" do testing.expectf(t, strings.contains(err.details_json, strings.concatenate({`"state":"`, c.state, `"`}, context.temp_allocator)), "case %d details %s", i, err.details_json)
		_, found, _ := iface.instance_reconfiguration_get(&h.ar, "owner", "inst", "refused")
		testing.expectf(t, !found, "case %d persisted no operation", i)
		testing.expect_value(t, len(h.commands), commands)
		after := start_test_row(t, h)
		testing.expect_value(t, after.configuration_revision, before.configuration_revision)
		testing.expect_value(t, after.runtime_transport_override, "")
	}
}

transport_idempotency_scenario :: proc(t: ^testing.T, h: ^Start_Test) {
	transport_test_ready(t, h, `"instance_reconfiguration_v1","acp_runtime_v1"`, TRANSPORT_ADAPTER_READY)
	op, accepted, err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("same-key", "acp"))
	if !testing.expect(t, accepted, err.message) do return
	replay, replayed, replay_err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("same-key", "acp"))
	testing.expect(t, replayed, replay_err.message)
	testing.expect_value(t, replay.operation_id, op.operation_id)
	for other in ([]string{"pty", ""}) {
		_, conflicted, conflict_err := begin_instance_reconfiguration(&h.service, start_test_auth(), "inst", transport_test_input("same-key", other))
		testing.expectf(t, !conflicted && conflict_err.code == .Conflict, "same key with transport %q must conflict: %v", other, conflict_err.code)
	}
	// The repository's own immutable-key guard also compares the choice.
	changed := op
	changed.phase = .Prepared; changed.revision = 1
	changed.destination.runtime_transport_override = "pty"
	_, began, begin_err := iface.instance_reconfiguration_begin(&h.ar, changed)
	testing.expect(t, !began && begin_err.code == .Conflict, "repository rejects another transport for the key")
}

@(test)
test_reconfiguration_transport_pty_pins_over_bridge_setting :: proc(t: ^testing.T) {start_test_run(t, transport_pty_scenario)}
@(test)
test_reconfiguration_transport_acp_commits_and_survives_relaunch :: proc(t: ^testing.T) {start_test_run(t, transport_acp_scenario)}
@(test)
test_reconfiguration_transport_omitted_keeps_derivation :: proc(t: ^testing.T) {start_test_run(t, transport_omitted_scenario)}
@(test)
test_reconfiguration_transport_refusals_write_nothing :: proc(t: ^testing.T) {start_test_run(t, transport_refusals_scenario)}
@(test)
test_reconfiguration_transport_is_part_of_idempotency :: proc(t: ^testing.T) {start_test_run(t, transport_idempotency_scenario)}

@(test)
test_reconfiguration_transport_override_validation :: proc(t: ^testing.T) {
	inst := domain.Agent_Instance{runtime_transport_override = "acp"}
	kept, ok, _ := reconfiguration_destination_transport_override(inst, "")
	testing.expect(t, ok)
	testing.expect_value(t, kept, "acp")
	set, set_ok, _ := reconfiguration_destination_transport_override(inst, " pty ")
	testing.expect(t, set_ok)
	testing.expect_value(t, set, "pty")
	_, bad_ok, bad_err := reconfiguration_destination_transport_override(inst, "native")
	testing.expect(t, !bad_ok && bad_err.code == .Invalid_Transport)
}
