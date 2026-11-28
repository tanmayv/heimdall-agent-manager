package http

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"

// Hub-side ACP delivery evidence and conversation-level Send now. Uses the real
// SQLite schema (including acp_delivery_001), unit of work and HTTP handlers.

Ad_Sink :: struct { commands: [dynamic]string, offline, refuse: bool, cause: string, allocator: mem.Allocator }
ad_sink_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
    sink := (^Ad_Sink)(ctx)
    if sink.offline do return false, domain.domain_error(.Bridge_Offline, "offline")
    append(&sink.commands, strings.clone(command.body_json, sink.allocator))
    return true, {}
}
// A sink that waits for the bridge's command_result (PTY Send now's outcome).
ad_sink_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
    sink := (^Ad_Sink)(ctx)
    if sink.offline do return "", false, domain.domain_error(.Bridge_Offline, "offline")
    append(&sink.commands, strings.clone(command.body_json, sink.allocator))
    if sink.refuse {
        err := domain.domain_error(.Conflict, "the agent runtime did not accept the command")
        err.cause = sink.cause
        return "", false, err
    }
    return strings.clone(`{"type":"command_result","status":"succeeded"}`), true, {}
}
ad_cmd :: proc(f: ^ACP_Chat_Fixture, kind: string, n: int) -> string {
    i := 0
    for c in f.delivery_sink.commands do if strings.contains(c, kind) { if i == n do return c; i += 1 }
    return ""
}
ad_count :: proc(f: ^ACP_Chat_Fixture, kind: string) -> int {
    n := 0
    for c in f.delivery_sink.commands do if strings.contains(c, kind) do n += 1
    return n
}

ad_open :: proc(t: ^testing.T, f: ^ACP_Chat_Fixture) {
    acp_chat_open(t, f)
    f.delivery_sink = {commands = make([dynamic]string), allocator = context.allocator}
    f.mq.svc.bridge_command_sink = {ctx = &f.delivery_sink, send_runtime_command = ad_sink_send}
}

ad_send :: proc(t: ^testing.T, f: ^ACP_Chat_Fixture, text: string) -> string {
    auth := contracts.Auth_Context{kind = .Session, user_id = f.mq.base.owner_user_id}
    m, ok, err := content_service.send_message(&f.mq.svc, auth, "chat_mq", {body = acp_chat_seal(text)})
    testing.expect(t, ok, err.message)
    return m.message_id
}

ad_report :: proc(f: ^ACP_Chat_Fixture, report: contracts.ACP_Input_State_Report, token := "hit_inst_mq~epoch") -> Response {
    raw, _ := json.marshal(struct{agent_instance_id: string, params: contracts.ACP_Input_State_Report}{"inst_mq", report}, allocator = context.temp_allocator)
    req := mq_http_req(f.mq.base, "/api/v1/agent-actions/chat/input-state", string(raw))
    req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.mq.base.bridge_token)}, {name = "X-Heimdall-Instance-Token", value = token}}
    return agent_action_chat_input_state_handler(&f.mq.agent_handlers, req)
}

ad_queued :: proc(f: ^ACP_Chat_Fixture, seq: i64, ids: ..string) -> Response {
    entries := make([dynamic]contracts.ACP_Input_State_Entry, context.temp_allocator)
    for id in ids do append(&entries, contracts.ACP_Input_State_Entry{message_id = id, state = "queued", hold_reason = "turn_active"})
    return ad_report(f, {launch_epoch = "epoch", report_seq = seq, inputs = entries[:]})
}

ad_send_now :: proc(f: ^ACP_Chat_Fixture, request_id: string, epoch := "epoch", ids: []string = nil, owner := "tanmay") -> Response {
    raw, _ := json.marshal(struct{request_id, launch_epoch: string, message_ids: []string}{request_id, epoch, ids}, allocator = context.temp_allocator)
    return send_now_handler(&f.mq.handlers, mq_http_req(f.mq.base, "/api/v1/chats/chat_mq/send-now", string(raw), owner))
}

ad_row :: proc(f: ^ACP_Chat_Fixture, id: string) -> domain.ACP_Input_Delivery {
    row, _, _ := iface.content_get_input_delivery(&f.mq.repo, id)
    return row
}

ad_message_json :: proc(f: ^ACP_Chat_Fixture, id: string) -> string {
    m, _, _ := iface.content_get_message(&f.mq.repo, id)
    b := strings.builder_make(context.temp_allocator)
    write_message_json(&b, m, &f.mq.svc)
    return strings.to_string(b)
}

ad_batch_of :: proc(body: string) -> (string, string, i64) {
    Payload :: struct { data: struct { outcome: string, batch: struct { batch_id, state: string, attempt: i64 } } }
    p: Payload
    _ = json.unmarshal_string(body, &p, allocator = context.temp_allocator)
    return p.data.outcome, p.data.batch.batch_id, p.data.batch.attempt
}

ad_arena :: proc() -> virtual.Arena { a: virtual.Arena; _ = virtual.arena_init_growing(&a); return a }

@(test)
ad_delivery_sinks_have_independent_lifetimes :: proc(t: ^testing.T) {
    first := ad_arena()
    second := ad_arena(); defer virtual.arena_destroy(&second)
    a, b: ACP_Chat_Fixture
    a.delivery_sink = {commands=make([dynamic]string, virtual.arena_allocator(&first)), allocator=virtual.arena_allocator(&first)}
    b.delivery_sink = {commands=make([dynamic]string, virtual.arena_allocator(&second)), allocator=virtual.arena_allocator(&second)}
    // A callback can run with a different ambient allocator. Its fixture owns
    // both the command buffer and bytes, independent of the other fixture.
    context.allocator = virtual.arena_allocator(&first)
    _, _ = ad_sink_send(&a.delivery_sink, {body_json="first"})
    _, _ = ad_sink_send(&b.delivery_sink, {body_json="second"})
    testing.expect_value(t, ad_count(&a,"first"), 1)
    testing.expect_value(t, ad_count(&b,"first"), 0)
    virtual.arena_destroy(&first)
    context.allocator = virtual.arena_allocator(&second)
    _, _ = ad_sink_send(&b.delivery_sink, {body_json="second later"})
    testing.expect_value(t, ad_count(&b,"second"), 2)
    testing.expect_value(t, ad_cmd(&b,"second",0), "second")
}

@(test)
ad_status_path_sent_queued_delivered_read_and_pty_unchanged :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    id := ad_send(t, &f, "hello")
    testing.expect_value(t, ad_row(&f, id).state, "sent")
    testing.expect(t, strings.contains(ad_message_json(&f, id), `"acp_delivery":{"status":"sent"`))
    // Bridge admission ack (prefetch) is NOT read evidence.
    req := mq_http_req(f.mq.base, "/api/v1/agent-actions/chat/read", fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"ack_message_ids":["%s"]}}}}`, id))
    req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.mq.base.bridge_token)}, {name = "X-Heimdall-Instance-Token", value = "hit_inst_mq~epoch"}}
    r := agent_action_chat_read_handler(&f.mq.agent_handlers, req); testing.expect(t, r.status == 200, r.body)
    testing.expect_value(t, ad_row(&f, id).agent_read_at, "")
    r = ad_queued(&f, 1, id); testing.expect(t, r.status == 200, r.body)
    testing.expect(t, strings.contains(ad_message_json(&f, id), `"status":"queued","state":"queued","hold_reason":"turn_active","tray_eligible":true`))
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 2, inputs = {{message_id = id, state = "delivered", mode = "prompt", turn_id = "ham:epoch:7"}}})
    testing.expect(t, r.status == 200, r.body)
    row := ad_row(&f, id)
    testing.expect(t, row.state == "delivered" && row.mode == "prompt" && row.delivered_at != "" && row.agent_read_at == "", "prompt acceptance is delivery, never read")
    msg, _, _ := iface.content_get_message(&f.mq.repo, id)
    testing.expect(t, msg.delivered_at != "", "chat_messages.delivered_at now has a writer")
    // Actual agent read (history mode, own conversation) is read evidence.
    req = mq_http_req(f.mq.base, "/api/v1/agent-actions/chat/read", `{"agent_instance_id":"inst_mq","params":{"unread_only":false}}`)
    req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.mq.base.bridge_token)}, {name = "X-Heimdall-Instance-Token", value = "hit_inst_mq~epoch"}}
    r = agent_action_chat_read_handler(&f.mq.agent_handlers, req); testing.expect(t, r.status == 200, r.body)
    testing.expect(t, ad_row(&f, id).agent_read_at != "")
    testing.expect(t, strings.contains(ad_message_json(&f, id), `"status":"read"`))
    // A PTY instance gets no delivery record: today's behavior is unchanged.
    inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
    inst.runtime_transport = "pty"; inst.run_count += 1; _, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
    pty := ad_send(t, &f, "pty")
    _, found, _ := iface.content_get_input_delivery(&f.mq.repo, pty)
    testing.expect(t, !found)
    testing.expect(t, !strings.contains(ad_message_json(&f, pty), "acp_delivery"))
}

@(test)
ad_hold_reasons_only_turn_active_is_tray_eligible_and_sticky :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    idle := ad_send(t, &f, "idle")
    offline := ad_send(t, &f, "not yet at bridge")
    held := ad_send(t, &f, "held")
    r := ad_report(&f, {launch_epoch = "epoch", report_seq = 1, inputs = {{message_id = idle, state = "queued", hold_reason = "dispatch_pending"}, {message_id = held, state = "queued", hold_reason = "turn_active"}}})
    testing.expect(t, r.status == 200, r.body)
    testing.expect(t, !content_service.acp_delivery_turn_held(ad_row(&f, idle)), "idle send is not a turn-held queue")
    testing.expect(t, !content_service.acp_delivery_turn_held(ad_row(&f, offline)), "offline/undelivered-to-bridge is not a turn-held queue")
    testing.expect_value(t, content_service.acp_delivery_status(ad_row(&f, offline)), "sent")
    testing.expect(t, content_service.acp_delivery_turn_held(ad_row(&f, held)))
    // Sticky: a later dispatch_pending report never flickers it out of the tray.
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 2, inputs = {{message_id = held, state = "queued", hold_reason = "dispatch_pending"}}})
    testing.expect_value(t, ad_row(&f, held).hold_reason, "turn_active")
    // A failed (vault/publication) message row never gets a queue state from the Hub.
    failed := ad_send(t, &f, "x")
    m, _, _ := iface.content_get_message(&f.mq.repo, failed)
    _, _, _ = iface.content_update_message(&f.mq.repo, m.owner_user_id, m.conversation_id, m.message_id, m.body, "failed", m.metadata_json)
    testing.expect(t, !content_service.acp_delivery_turn_held(ad_row(&f, failed)))
    // Send now ignores everything that is not turn-held.
    r = ad_send_now(&f, "req_only_held")
    testing.expect(t, r.status == 202, r.body)
    testing.expect_value(t, ad_count(&f,"acp_send_now_batch"), 1)
    testing.expect(t, strings.contains(ad_cmd(&f,"acp_send_now_batch",0), held) && !strings.contains(ad_cmd(&f,"acp_send_now_batch",0), idle) && !strings.contains(ad_cmd(&f,"acp_send_now_batch",0), offline))
}

@(test)
ad_reports_are_monotonic_epoch_fenced_and_validated :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    id := ad_send(t, &f, "a")
    r := ad_report(&f, {launch_epoch = "epoch", report_seq = 5, inputs = {{message_id = id, state = "delivered", mode = "steer", turn_id = "t"}}})
    testing.expect(t, r.status == 200, r.body)
    // An older or replayed report never moves a row backwards.
    r = ad_queued(&f, 4, id); testing.expect_value(t, r.status, 200)
    r = ad_queued(&f, 9, id); testing.expect_value(t, r.status, 200)
    testing.expect_value(t, ad_row(&f, id).state, "delivered")
    testing.expect_value(t, ad_row(&f, id).mode, "steer")
    // Invalid shapes are rejected; the assertion epoch must match the report.
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 10, inputs = {{message_id = id, state = "delivered"}}})
    testing.expect_value(t, r.status, 400)
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 10, inputs = {{message_id = "x", state = "queued"}}})
    testing.expect_value(t, r.status, 400)
    r = ad_report(&f, {launch_epoch = "other", report_seq = 11})
    testing.expect_value(t, r.status, 403)
    // Another conversation's message is never touched.
    _, ok, _ := iface.content_save_message(&f.mq.repo, {message_id = "msg_foreign", conversation_id = "chat_other", owner_user_id = "tanmay", direction = "user_to_agent", body = acp_chat_seal("f"), created_at = "now"})
    testing.expect(t, ok)
    r = ad_queued(&f, 12, "msg_foreign"); testing.expect_value(t, r.status, 200)
    _, found, _ := iface.content_get_input_delivery(&f.mq.repo, "msg_foreign")
    testing.expect(t, !found)
}

@(test)
ad_send_now_snapshot_fifo_cutoff_duplicate_and_empty :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    a := ad_send(t, &f, "a"); b := ad_send(t, &f, "b"); c := ad_send(t, &f, "c")
    r := ad_queued(&f, 1, a, b, c); testing.expect(t, r.status == 200, r.body)
    // Client snapshot names a and b only: c arrived after the user's view.
    r = ad_send_now(&f, "req_1", ids = {a, b})
    testing.expect(t, r.status == 202, r.body)
    outcome, batch, attempt := ad_batch_of(r.body)
    testing.expect_value(t, outcome, "accepted"); testing.expect_value(t, attempt, 1)
    testing.expect_value(t, ad_count(&f,"acp_send_now_batch"), 1)
    cmd: contracts.ACP_Send_Now_Batch_Command
    testing.expect(t, json.unmarshal_string(ad_cmd(&f,"acp_send_now_batch",0), &cmd) == nil)
    testing.expect(t, len(cmd.message_ids) == 2 && cmd.message_ids[0] == a && cmd.message_ids[1] == b, "FIFO snapshot within the cutoff")
    testing.expect_value(t, cmd.command_id, fmt.tprintf("cmd_sn_%s_a1", batch))
    testing.expect_value(t, ad_row(&f, a).batch_id, batch)
    testing.expect_value(t, ad_row(&f, c).batch_id, "")
    // Same request (double click) and a different request while pending: no second command.
    r = ad_send_now(&f, "req_1", ids = {a, b}); outcome, _, _ = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "duplicate")
    r = ad_send_now(&f, "req_2"); outcome, _, _ = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "duplicate")
    testing.expect_value(t, ad_count(&f,"acp_send_now_batch"), 1)
    // Bridge delivers the batch as one prompt.
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 2, batch_id = batch, batch_attempt = 1, batch_state = "delivered",
        inputs = {{message_id = a, state = "delivered", mode = "prompt", turn_id = "T", batch_id = batch}, {message_id = b, state = "delivered", mode = "prompt", turn_id = "T", batch_id = batch}}})
    testing.expect(t, r.status == 200, r.body)
    r = ad_send_now(&f, "req_1"); outcome, _, _ = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "delivered")
    // A new request now covers only c, the later arrival.
    r = ad_send_now(&f, "req_3"); testing.expect(t, r.status == 202, r.body)
    testing.expect(t, strings.contains(ad_cmd(&f,"acp_send_now_batch",1), c) && !strings.contains(ad_cmd(&f,"acp_send_now_batch",1), a))
    // Nothing queued: empty, no command, no cancellation.
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 3, inputs = {{message_id = c, state = "delivered", mode = "prompt", turn_id = "U"}}})
    r = ad_send_now(&f, "req_4"); outcome, _, _ = ad_batch_of(r.body)
    testing.expect(t, r.status == 200 || r.status == 202, r.body)
    if outcome != "duplicate" do testing.expect_value(t, outcome, "empty")
}

@(test)
ad_send_now_retry_stale_offline_and_ownership :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    a := ad_send(t, &f, "a"); b := ad_send(t, &f, "b")
    r := ad_queued(&f, 1, a, b)
    r = ad_send_now(&f, "req_s", epoch = "old"); testing.expect_value(t, r.status, 409)
    r = ad_send_now(&f, "req_o", owner = "other-user"); testing.expect(t, r.status == 403 || r.status == 404, r.body)
    r = ad_send_now(&f, ""); testing.expect_value(t, r.status, 400)
    // Bridge offline: honest failure, then an explicit retry gets attempt 2.
    f.delivery_sink.offline = true
    r = ad_send_now(&f, "req_r"); testing.expect_value(t, r.status, 503)
    outcome, batch, _ := ad_batch_of(r.body); testing.expect_value(t, outcome, "failed")
    f.delivery_sink.offline = false
    // Meanwhile the agent actually reads b: retry excludes it.
    req := mq_http_req(f.mq.base, "/api/v1/agent-actions/chat/read", `{"agent_instance_id":"inst_mq","params":{"unread_only":false}}`)
    req.headers = {{name = "Authorization", value = fmt.tprintf("Bearer %s", f.mq.base.bridge_token)}, {name = "X-Heimdall-Instance-Token", value = "hit_inst_mq~epoch"}}
    sb, _, _ := iface.content_get_input_delivery(&f.mq.repo, a)
    _ = sb
    rows_before := ad_count(&f,"acp_inputs_read")
    r = agent_action_chat_read_handler(&f.mq.agent_handlers, req); testing.expect(t, r.status == 200, r.body)
    testing.expect(t, ad_count(&f,"acp_inputs_read") == rows_before+1, "bridge is told to drop read inputs")
    testing.expect_value(t, ad_row(&f, b).mode, "read")
    testing.expect_value(t, ad_row(&f, a).mode, "read")
    // Both read: the retry has nothing left and sends nothing.
    attempt: i64
    r = ad_send_now(&f, "req_r"); outcome, _, attempt = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "empty"); testing.expect_value(t, attempt, 2)
    testing.expect_value(t, ad_count(&f,"acp_send_now_batch"), 0)
    _ = batch
    // Retry after a bridge-reported failure re-sends with an attempt-specific id.
    c := ad_send(t, &f, "c"); r = ad_queued(&f, 2, c)
    r = ad_send_now(&f, "req_t"); _, batch, _ = ad_batch_of(r.body)
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 3, batch_id = batch, batch_attempt = 1, batch_state = "failed", batch_error = "cancel_timeout"})
    testing.expect(t, r.status == 200, r.body)
    // A late report for an older attempt never overrides the retry.
    r = ad_send_now(&f, "req_t"); outcome, _, attempt = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "accepted"); testing.expect_value(t, attempt, 2)
    testing.expect(t, strings.contains(ad_cmd(&f,"acp_send_now_batch", ad_count(&f,"acp_send_now_batch")-1), fmt.tprintf("cmd_sn_%s_a2", batch)))
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 4, batch_id = batch, batch_attempt = 1, batch_state = "delivered"})
    got, _, _ := iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect_value(t, got.state, "sent")
    // A stalled command (no bridge progress) becomes retryable.
    got.updated_at = "2020-01-01T00:00:00Z"; _ = iface.content_save_send_now_batch(&f.mq.repo, got)
    r = ad_send_now(&f, "req_t"); outcome, _, attempt = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "accepted"); testing.expect_value(t, attempt, 3)
}

@(test)
ad_relaunch_reopens_never_dispatched_and_discards_inflight :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    a := ad_send(t, &f, "a"); b := ad_send(t, &f, "b")
    r := ad_report(&f, {launch_epoch = "epoch", report_seq = 1, inputs = {{message_id = a, state = "queued", hold_reason = "turn_active"}, {message_id = b, state = "dispatching", hold_reason = "turn_active"}}})
    r = ad_send_now(&f, "req_x", ids = {a}); _, batch, _ := ad_batch_of(r.body)
    _, _ = content_service.mark_messages_read_by_ids(&f.mq.svc, {kind = .Session, user_id = "tanmay"}, {a, b})
    inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
    inst.launch_epoch = "epoch2"; inst.run_count += 1; _, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
    notes := ad_count(&f,"notify_agent_message")
    r = ad_report(&f, {launch_epoch = "epoch2", report_seq = 1, steering_supported = true}, "hit_inst_mq~epoch2")
    testing.expect(t, r.status == 200, r.body)
    ra := ad_row(&f, a)
    testing.expect(t, ra.state == "sent" && ra.launch_epoch == "" && ra.batch_id == "", "never-dispatched input is reopened for re-admission")
    m, _, _ := iface.content_get_message(&f.mq.repo, a)
    testing.expect_value(t, m.read_at, "")
    testing.expect_value(t, ad_row(&f, b).state, "discarded")
    testing.expect_value(t, ad_row(&f, b).error, "agent_restarted")
    got, _, _ := iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect(t, got.state == "failed" && got.error == "agent_restarted")
    testing.expect(t, ad_count(&f,"notify_agent_message") > notes, "bridge gets a fetch edge for re-admission")
    rt, have, _ := iface.content_get_input_runtime(&f.mq.repo, "inst_mq")
    testing.expect(t, have && rt.steering_supported && rt.launch_epoch == "epoch2")
    // A late report from the old epoch cannot touch the reopened row.
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 9, inputs = {{message_id = a, state = "delivered", mode = "prompt", turn_id = "old"}}})
    testing.expect(t, r.status == 200, r.body)
    testing.expect_value(t, ad_row(&f, a).state, "sent")
    // GET exposes the runtime facts and the latest batch.
    req := mq_http_req(f.mq.base, "/api/v1/chats/chat_mq/send-now", ""); req.method = "GET"
    r = get_send_now_handler(&f.mq.handlers, req)
    testing.expect(t, r.status == 200 && strings.contains(r.body, `"steering_supported":true`) && strings.contains(r.body, `"launch_epoch":"epoch2"`), r.body)
}

// The relayed segment names every user input it answers (one prompt or a
// steered batch) so the UI can place it causally; nothing is stored.
@(test)
ad_assistant_segment_relays_all_batch_input_ids :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    b: Acp_Chat_Bus; b.slot = -1; defer acp_chat_bus_close(&b)
    if !acp_chat_bus_open(t, &f, &b) do return
    a := ad_send(t, &f, "a"); c := ad_send(t, &f, "b")
    for _ in 0..<2 do _ = acp_chat_bus_frame(&b) // the two sends' own chat events
    input := contracts.ACP_Assistant_Message_Input{launch_epoch = "epoch", turn_id = "turn", message_id = "msg_0123456789abcdef", revision = 1, body = acp_chat_seal("answer"), message_status = "pending", input_ids = {a, c}}
    r := acp_chat_call(&f, input); testing.expect(t, r.status == 200, r.body)
    frame := acp_chat_bus_frame(&b)
    testing.expect(t, strings.contains(frame, fmt.tprintf(`"input_ids":["%s","%s"]`, a, c)), frame)
    _, found, _ := iface.content_get_message(&f.mq.repo, input.message_id)
    testing.expect(t, !found)
    input.revision = 2; input.input_ids = {"bad id"}
    r = acp_chat_call(&f, input); testing.expect_value(t, r.status, 400)
}

ad_agent_req :: proc(f: ^ACP_Chat_Fixture, path, body: string) -> Request {
    req := mq_http_req(f.mq.base, path, body)
    // Heap-backed: a slice literal would point into this returning frame.
    headers := make([]contracts.HTTP_Header, 2)
    headers[0] = {name = "Authorization", value = fmt.tprintf("Bearer %s", f.mq.base.bridge_token)}
    headers[1] = {name = "X-Heimdall-Instance-Token", value = "hit_inst_mq~epoch"}
    req.headers = headers
    return req
}

// Review blocker (rev 4): the bridge's admission ack sets legacy read_at, so the
// agent's DEFAULT unread read must still return a queued, never-delivered input
// and record actual read evidence for it.
@(test)
ad_default_unread_agent_read_after_bridge_admission_is_read_evidence :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    held := ad_send(t, &f, "held by turn")
    prompted := ad_send(t, &f, "already prompted")
    // Bridge admission ack of both inputs (legacy read_at), then queue reports.
    r := agent_action_chat_read_handler(&f.mq.agent_handlers, ad_agent_req(&f, "/api/v1/agent-actions/chat/read", fmt.tprintf(`{{"agent_instance_id":"inst_mq","params":{{"ack_message_ids":["%s","%s"]}}}}`, held, prompted)))
    testing.expect(t, r.status == 200, r.body)
    m, _, _ := iface.content_get_message(&f.mq.repo, held)
    testing.expect(t, m.read_at != "", "bridge admission sets legacy read_at")
    r = ad_queued(&f, 1, held, prompted); testing.expect(t, r.status == 200, r.body)
    r = ad_report(&f, {launch_epoch = "epoch", report_seq = 2, inputs = {{message_id = prompted, state = "delivered", mode = "prompt", turn_id = "ham:epoch:1"}}})
    testing.expect(t, r.status == 200, r.body)
    testing.expect(t, content_service.acp_delivery_turn_held(ad_row(&f, held)))
    // The bridge's own input drain keeps the legacy filter: admission never loops.
    r = agent_action_chat_fetch_handler(&f.mq.agent_handlers, ad_agent_req(&f, "/api/v1/agent-actions/chat/fetch", `{"agent_instance_id":"inst_mq","params":{"input_source":"bridge_acp","unread_only":true,"receiver_only":true,"oldest_first":true,"limit":100}}`))
    testing.expect(t, r.status == 200, r.body)
    testing.expect(t, !strings.contains(r.body, held) && !strings.contains(r.body, prompted), r.body)
    testing.expect_value(t, ad_row(&f, held).agent_read_at, "")
    // The agent's default `ham-ctl chat read` (unread_only=true, mark_read).
    r = agent_action_chat_read_handler(&f.mq.agent_handlers, ad_agent_req(&f, "/api/v1/agent-actions/chat/read", `{"agent_instance_id":"inst_mq","params":{"limit":50}}`))
    testing.expect(t, r.status == 200, r.body)
    testing.expect(t, strings.contains(r.body, held), "queued admitted input is unread for the agent")
    testing.expect(t, !strings.contains(r.body, prompted), "delivered input is not resurfaced as unread")
    testing.expect(t, strings.contains(r.body, `"unread_count_before":1,"unread_count_after":0`), r.body)
    row := ad_row(&f, held)
    testing.expect(t, row.agent_read_at != "" && row.state == "delivered" && row.mode == "read", "actual read implies delivery")
    testing.expect(t, !content_service.acp_delivery_turn_held(row), "read clears tray eligibility")
    testing.expect(t, strings.contains(ad_message_json(&f, held), `"status":"read"`))
    testing.expect_value(t, ad_row(&f, prompted).agent_read_at, "")
    testing.expect_value(t, ad_count(&f,contracts.ACP_INPUTS_READ_COMMAND), 1)
    testing.expect(t, strings.contains(ad_cmd(&f,contracts.ACP_INPUTS_READ_COMMAND, 0), held), "bridge drops the read input from its queue")
    // Send now no longer selects it; a repeat default read returns nothing new.
    r = ad_send_now(&f, "req_after_read")
    outcome, _, _ := ad_batch_of(r.body)
    testing.expect_value(t, outcome, "empty")
    r = agent_action_chat_read_handler(&f.mq.agent_handlers, ad_agent_req(&f, "/api/v1/agent-actions/chat/read", `{"agent_instance_id":"inst_mq","params":{}}`))
    testing.expect(t, r.status == 200 && !strings.contains(r.body, held), r.body)
    testing.expect_value(t, ad_count(&f,contracts.ACP_INPUTS_READ_COMMAND), 1)
}

// A runtime without members (PTY): Send now is accepted for it, dispatched
// with no message ids, its outcome is the bridge's command result, and a
// repeat of the same request is a no-op.
@(test)
ad_pty_send_now_is_memberless_and_idempotent_per_request :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    f.mq.svc.bridge_command_sink.send_runtime_command_wait = ad_sink_wait
    inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
    inst.runtime_transport = "pty"; inst.run_count += 1; _, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
    a := ad_send(t, &f, "a")
    _, tracked, _ := iface.content_get_input_delivery(&f.mq.repo, a)
    testing.expect(t, !tracked, "PTY rows keep no delivery record")
    g := get_send_now_handler(&f.mq.handlers, mq_http_req(f.mq.base, "/api/v1/chats/chat_mq/send-now", ""))
    testing.expect(t, g.status == 200 && strings.contains(g.body, `"send_now":"notice"`), g.body)
    r := ad_send_now(&f, "req_p", ids = {a}); testing.expect(t, r.status == 200, r.body)
    outcome, batch, attempt := ad_batch_of(r.body)
    testing.expect_value(t, outcome, "delivered"); testing.expect_value(t, attempt, 1)
    testing.expect_value(t, ad_count(&f, "acp_send_now_batch"), 1)
    cmd: contracts.ACP_Send_Now_Batch_Command
    testing.expect(t, json.unmarshal_string(ad_cmd(&f, "acp_send_now_batch", 0), &cmd, allocator = context.temp_allocator) == nil)
    testing.expect(t, cmd.batch_id == batch && cmd.attempt == 1 && cmd.launch_epoch == "epoch" && len(cmd.message_ids) == 0, "dispatched without members")
    testing.expect_value(t, cmd.command_id, fmt.tprintf("cmd_sn_%s_a1", batch))
    got, _, _ := iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect(t, got.state == "delivered" && got.member_ids_json == "[]", got.state)
    // A repeat click with the same request is a no-op.
    r = ad_send_now(&f, "req_p"); outcome, _, _ = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "delivered")
    testing.expect_value(t, ad_count(&f, "acp_send_now_batch"), 1)
    // A refused command is an honest failure; the retry bumps the attempt.
    f.delivery_sink.refuse = true
    r = ad_send_now(&f, "req_q"); testing.expect_value(t, r.status, 503)
    outcome, batch, _ = ad_batch_of(r.body); testing.expect_value(t, outcome, "failed")
    got, _, _ = iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect_value(t, got.error, "send_failed")
    f.delivery_sink.refuse = false
    r = ad_send_now(&f, "req_q"); outcome, _, attempt = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "delivered"); testing.expect_value(t, attempt, 2)
    testing.expect(t, strings.contains(ad_cmd(&f, "acp_send_now_batch", 2), fmt.tprintf("cmd_sn_%s_a2", batch)))
    // An offline bridge fails honestly; a stale epoch is refused.
    f.delivery_sink.offline = true
    r = ad_send_now(&f, "req_o"); testing.expect_value(t, r.status, 503)
    outcome, batch, _ = ad_batch_of(r.body); testing.expect_value(t, outcome, "failed")
    got, _, _ = iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect_value(t, got.error, "bridge_offline")
    f.delivery_sink.offline = false
    r = ad_send_now(&f, "req_s", epoch = "old"); testing.expect_value(t, r.status, 409)
    testing.expect_value(t, ad_count(&f, "acp_send_now_batch"), 3)
}

// A memberless Send now the runtime did not deliver is never recorded as
// delivered: a stopped agent fails with agent_stopped, and a held-back one
// (a context rollover) is reported queued with its reason; the bridge
// keeps the notice, and a retry once it can type delivers.
@(test)
ad_pty_send_now_not_delivered_reports_the_runtime_reason :: proc(t: ^testing.T) {
    arena := ad_arena(); defer virtual.arena_destroy(&arena)
    context.allocator = virtual.arena_allocator(&arena); context.temp_allocator = context.allocator
    f: ACP_Chat_Fixture; ad_open(t, &f); defer mq_http_base_close(f.mq.base)
    f.mq.svc.bridge_command_sink.send_runtime_command_wait = ad_sink_wait
    inst, _, _ := iface.agent_get_instance(&f.mq.base.ag_repo, "inst_mq")
    inst.runtime_transport = "pty"; inst.run_count += 1; _, _, _ = iface.agent_save_instance(&f.mq.base.ag_repo, inst)
    _ = ad_send(t, &f, "a")
    f.delivery_sink.refuse = true
    f.delivery_sink.cause = contracts.RUNTIME_SEND_NOW_CAUSE[.Not_Running]
    r := ad_send_now(&f, "req_dead"); testing.expect_value(t, r.status, 503)
    outcome, batch, _ := ad_batch_of(r.body); testing.expect_value(t, outcome, "failed")
    got, _, _ := iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect(t, got.state == "failed" && got.error == "agent_stopped", got.error)
    f.delivery_sink.cause = contracts.RUNTIME_SEND_NOW_CAUSE[.Held]
    r = ad_send_now(&f, "req_held"); testing.expect_value(t, r.status, 202)
    outcome, batch, _ = ad_batch_of(r.body); testing.expect_value(t, outcome, "queued")
    got, _, _ = iface.content_get_send_now_batch(&f.mq.repo, batch)
    testing.expect(t, got.state == "failed" && got.error == "held", got.error)
    f.delivery_sink.refuse = false; f.delivery_sink.cause = ""
    attempt: i64
    r = ad_send_now(&f, "req_held"); outcome, _, attempt = ad_batch_of(r.body)
    testing.expect_value(t, outcome, "delivered"); testing.expect_value(t, attempt, 2)
}
