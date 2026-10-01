package shell_session

// REQ-SHELL-5 acceptance tests — "notify BACKGROUND runs only, and leave exactly one
// lean marker in the triggering conversation".
//
// The two halves under test are deliberately independent of each other, and each test
// below pins exactly one of them:
//
//   THE NOTIFICATION  a transient nudge, emitted from shell_session_handle_exited,
//                     gated on kind=run AND session.background.
//   THE MARKER        one chat message, emitted from shell_session_create, gated on
//                     kind=run and a resolved conversation.
//
//   AC1  a BACKGROUND run that completes notifies; so does one that is KILLED
//   AC2  a FOREGROUND run that completes notifies NOT AT ALL  <- the likeliest regression
//   AC3  a foreground run CONVERTED to background mid-flight notifies on completion
//   AC4  exactly ONE shell_run message per run, on every status path, conversion included
//   AC5  the message lands in the triggering conversation and is ABSENT from every other
//   AC6  metadata_json carries the session id and nothing else; the body carries no output
//   AC7  command output never reaches the hub DB by this path
//
// HOW THE ASSERTIONS ARE MADE, and why this shape rather than an event bus: the
// notification leaves the hub as a runtime command on the Bridge_Command_Sink, so a
// recording sink is the honest observation point — it is the actual wire, not a proxy
// for it. Counting `notify_shell_run` bodies in that recording is therefore a direct
// measurement of "did the agent get told", and its ABSENCE is a direct measurement of
// AC2, which is the criterion the task singles out as most likely to regress.
//
// The marker is observed the same way: a fake Content_Repository records every message
// saved, so "exactly one" is a count over real writes rather than an inspection of
// intent.

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import content_service "odin_test:hub/service/content"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import project_service "odin_test:hub/service/project"

// --- fake shell-session repository -------------------------------------------
//
// Permissive storage, exactly like Repo4's: every decision under test belongs to the
// service, so a repository that enforced any of them would hide a wrong decision
// behind a right storage layer.

@(private = "file")
Repo5 :: struct {
	stored: map[string]domain.Shell_Session,
}

@(private = "file")
r5_upsert :: proc(ctx: rawptr, session: domain.Shell_Session) -> (bool, domain.Domain_Error) {
	r := (^Repo5)(ctx)
	r.stored[session.session_id] = session
	return true, domain.Domain_Error{}
}

@(private = "file")
r5_get :: proc(ctx: rawptr, owner_user_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo5)(ctx)
	s, had := r.stored[session_id]
	if !had || s.owner_user_id != owner_user_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r5_get_by_id :: proc(ctx: rawptr, bridge_id, session_id: string) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	r := (^Repo5)(ctx)
	s, had := r.stored[session_id]
	if !had || s.bridge_id != bridge_id do return domain.Shell_Session{}, false, domain.Domain_Error{}
	return s, true, domain.Domain_Error{}
}

@(private = "file")
r5_find_live_by_port :: proc(ctx: rawptr, bridge_id: string, server_port: int) -> (domain.Shell_Session, bool, domain.Domain_Error) {
	return domain.Shell_Session{}, false, domain.Domain_Error{}
}

@(private = "file")
r5_count_live :: proc(ctx: rawptr, owner_user_id, kind, scope_column, scope_value: string) -> (int, domain.Domain_Error) {
	return 0, domain.Domain_Error{}
}

// --- fake content repository --------------------------------------------------
//
// Two conversations exist throughout, and that is the point: AC5 is only meaningful if
// there is somewhere else the message COULD have landed. conv_a belongs to the agent
// that starts every run here; conv_b belongs to a different agent and must stay empty.

@(private = "file")
CONV_A :: "chat_a"
@(private = "file")
CONV_B :: "chat_b"
@(private = "file")
INST_A :: "inst_a"
@(private = "file")
INST_B :: "inst_b"

@(private = "file")
Content5 :: struct {
	conversations: map[string]domain.Chat_Conversation,
	messages:      [dynamic]domain.Chat_Message,
}

@(private = "file")
c5_get_conversation :: proc(ctx: rawptr, id: string) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	c := (^Content5)(ctx)
	conv, had := c.conversations[id]
	if !had do return domain.Chat_Conversation{}, false, domain.domain_error(.Not_Found, "conversation not found")
	return conv, true, domain.Domain_Error{}
}

@(private = "file")
c5_save_conversation :: proc(ctx: rawptr, conv: domain.Chat_Conversation) -> (domain.Chat_Conversation, bool, domain.Domain_Error) {
	c := (^Content5)(ctx)
	c.conversations[conv.conversation_id] = conv
	return conv, true, domain.Domain_Error{}
}

// c5_list_conversations backs content_service.get_conversation_by_instance, which is
// how shell_session_create resolves a run's conversation from the caller's TOKEN
// rather than from the request body. Both conversations are returned, unordered as far
// as the caller is concerned, so a create that picked the wrong one would be visible.
@(private = "file")
c5_list_conversations :: proc(ctx: rawptr, owner: domain.User_ID, limit: int, cursor: string) -> ([]domain.Chat_Conversation, domain.Domain_Error) {
	c := (^Content5)(ctx)
	out := make([dynamic]domain.Chat_Conversation, context.temp_allocator)
	for _, conv in c.conversations {
		if conv.owner_user_id == owner do append(&out, conv)
	}
	return out[:], domain.Domain_Error{}
}

@(private = "file")
c5_save_message :: proc(ctx: rawptr, m: domain.Chat_Message) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	c := (^Content5)(ctx)
	append(&c.messages, m)
	return m, true, domain.Domain_Error{}
}

// c5_messages_in returns the shell_run markers recorded against one conversation.
@(private = "file")
c5_markers_in :: proc(c: ^Content5, conversation_id: string) -> int {
	n := 0
	for m in c.messages {
		if m.conversation_id == conversation_id && m.message_type == content_service.SHELL_RUN_MESSAGE_TYPE do n += 1
	}
	return n
}

@(private = "file")
c5_first_marker :: proc(c: ^Content5) -> (domain.Chat_Message, bool) {
	for m in c.messages {
		if m.message_type == content_service.SHELL_RUN_MESSAGE_TYPE do return m, true
	}
	return domain.Chat_Message{}, false
}

// --- recording bridge sink ----------------------------------------------------

@(private = "file")
Sink5 :: struct {
	bodies: [dynamic]string,
}

// s5_send_wait answers the shell_start round trip with a success reply so a create
// reaches its Running state, and records every body. shell_start and notify_shell_run
// therefore both land in the same recording, which is deliberate: it proves the
// notification counting below is not accidentally counting starts.
@(private = "file")
s5_send_wait :: proc(ctx: rawptr, command: project_service.Runtime_Command, timeout_ms: int) -> (string, bool, domain.Domain_Error) {
	_ = timeout_ms
	s := (^Sink5)(ctx)
	append(&s.bodies, strings.clone(command.body_json))
	// CLONED, not a literal: shell_session_create takes ownership of the reply and
	// frees it (`defer delete(reply)`), so handing back a string literal here would be
	// a bad free inside the code under test — a fixture bug that reads exactly like a
	// product bug in the tracking allocator's report.
	return strings.clone(`{"ok":true,"pid":4242}`), true, domain.Domain_Error{}
}

@(private = "file")
s5_send :: proc(ctx: rawptr, command: project_service.Runtime_Command) -> (bool, domain.Domain_Error) {
	s := (^Sink5)(ctx)
	append(&s.bodies, strings.clone(command.body_json))
	return true, domain.Domain_Error{}
}

// s5_notify_count counts notify_shell_run commands naming this session. Counting BY
// SESSION rather than in total is what makes "the foreground run did not notify"
// provable in a fixture that also ran a background one.
@(private = "file")
s5_notify_count :: proc(s: ^Sink5, session_id: string) -> int {
	n := 0
	needle := strings.concatenate({`"session_id":"`, session_id, `"`}, context.temp_allocator)
	for b in s.bodies {
		if strings.contains(b, `"type":"notify_shell_run"`) && strings.contains(b, needle) do n += 1
	}
	return n
}

@(private = "file")
s5_notify_body :: proc(s: ^Sink5, session_id: string) -> (string, bool) {
	needle := strings.concatenate({`"session_id":"`, session_id, `"`}, context.temp_allocator)
	for b in s.bodies {
		if strings.contains(b, `"type":"notify_shell_run"`) && strings.contains(b, needle) do return b, true
	}
	return "", false
}

// --- fixture ------------------------------------------------------------------

@(private = "file")
Fx5 :: struct {
	svc:     Shell_Session_Service,
	repo:    iface.Shell_Session_Repository,
	r:       Repo5,
	content_repo: iface.Content_Repository,
	content: Content5,
	csvc:    content_service.Content_Service,
	sink:    Sink5,
	ids:     platform.ID_Generator,
	clk:     platform.Clock,
}

@(private = "file")
now5 :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-09-28T13:00:00Z" }

@(private = "file")
fx5_make :: proc(fx: ^Fx5) {
	fx.r.stored = make(map[string]domain.Shell_Session)
	fx.content.conversations = make(map[string]domain.Chat_Conversation)
	fx.content.messages = make([dynamic]domain.Chat_Message)
	fx.sink.bodies = make([dynamic]string)

	fx.content.conversations[CONV_A] = domain.Chat_Conversation{
		conversation_id = CONV_A, owner_user_id = "owner_a", agent_instance_id = INST_A, agent_id = "agt_a",
	}
	fx.content.conversations[CONV_B] = domain.Chat_Conversation{
		conversation_id = CONV_B, owner_user_id = "owner_a", agent_instance_id = INST_B, agent_id = "agt_b",
	}

	fx.content_repo = iface.Content_Repository{
		ctx                = rawptr(&fx.content),
		get_conversation   = c5_get_conversation,
		save_conversation  = c5_save_conversation,
		list_conversations = c5_list_conversations,
		save_message       = c5_save_message,
	}
	fx.ids = platform.real_id_generator()
	fx.clk = platform.Clock{ctx = nil, now = now5}
	fx.csvc = content_service.Content_Service{content = &fx.content_repo, clock = &fx.clk, ids = &fx.ids}

	fx.repo = iface.Shell_Session_Repository{
		ctx               = rawptr(&fx.r),
		upsert            = r5_upsert,
		get               = r5_get,
		get_by_id         = r5_get_by_id,
		find_live_by_port = r5_find_live_by_port,
		count_live        = r5_count_live,
	}
	fx.svc = new_shell_session_service(
		repo                = &fx.repo,
		bridge_command_sink = project_service.Bridge_Command_Sink{
			ctx                       = rawptr(&fx.sink),
			send_runtime_command_wait = s5_send_wait,
			send_runtime_command      = s5_send,
		},
		ids     = &fx.ids,
		clock   = &fx.clk,
		content = &fx.csvc,
	)
}

@(private = "file")
fx5_free :: proc(fx: ^Fx5) {
	shell_session_service_free(&fx.svc)
	for b in fx.sink.bodies do delete(b)
	delete(fx.sink.bodies)
	delete(fx.content.messages)
	delete(fx.content.conversations)
	delete(fx.r.stored)
}

@(private = "file")
agent5_auth :: proc() -> contracts.Auth_Context {
	return contracts.Auth_Context{kind = .Instance_Token, user_id = "owner_a", agent_instance_id = INST_A}
}

// fx5_start_run creates a run through the real service path, so every test exercises
// the same create the product does — marker emission included.
@(private = "file")
fx5_start_run :: proc(fx: ^Fx5, background: bool) -> domain.Shell_Session {
	session, _, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id  = "brg_1",
		kind       = domain.Shell_Session_Kind_Run,
		cmd        = "echo hi",
		background = background,
	})
	return session
}

// --- AC1: a background run notifies on completion ------------------------------

@(test)
test_req5_background_run_notifies_on_completion :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	testing.expect(t, s.session_id != "", "run should have been created")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 0)

	applied := shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect(t, applied, "the exit should have been applied")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 1)

	// The notice must carry the SESSION ID — that is the handle the agent was given
	// when the run was backgrounded (REQ-SHELL-5 §1).
	body, found := s5_notify_body(&fx.sink, s.session_id)
	testing.expect(t, found, "a notify_shell_run should have been sent")
	testing.expect(t, strings.contains(body, s.session_id), "the notice must carry the session id")
	testing.expect(t, strings.contains(body, INST_A), "the notice must name the owning agent")
}

// --- AC1: a KILLED background run notifies too ---------------------------------

@(test)
test_req5_killed_background_run_notifies :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	applied := shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Killed, -1, true)
	testing.expect(t, applied, "the kill should have been applied")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 1)

	body, _ := s5_notify_body(&fx.sink, s.session_id)
	testing.expect(t, strings.contains(body, domain.Shell_Session_Status_Killed), "the notice must report the killed status")
}

// --- AC2: a FOREGROUND run notifies NOT AT ALL ---------------------------------
//
// The criterion the task names as most likely to regress, so it is asserted on both
// terminal outcomes rather than only on the happy one.

@(test)
test_req5_foreground_run_never_notifies :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	testing.expect(t, !s.background, "the run should be foreground")

	applied := shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect(t, applied, "the exit should still have been APPLIED — only the notice is suppressed")
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 0)
}

@(test)
test_req5_killed_foreground_run_never_notifies :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Killed, -1, true)
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 0)
}

// --- AC3: a foreground run CONVERTED to background does notify -----------------

@(test)
test_req5_converted_run_notifies_on_completion :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	testing.expect(t, !s.background, "the run starts foreground")

	converted, ok, _ := shell_session_set_background(&fx.svc, agent5_auth(), s.session_id)
	testing.expect(t, ok, "the conversion should succeed on a live run")
	testing.expect(t, converted.background, "the run should now be background")

	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, s5_notify_count(&fx.sink, s.session_id), 1)
}

// --- AC4: exactly ONE marker per run, on every status path ---------------------

@(test)
test_req5_exactly_one_marker_per_run :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)

	// Every subsequent status transition must add nothing. The duplicate exit is not
	// padding: an at-least-once outbox really does redeliver, and a marker emitted on
	// status change rather than at creation would show up here as a second message.
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)
}

@(test)
test_req5_conversion_does_not_add_a_second_marker :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, false)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)

	_, ok, _ := shell_session_set_background(&fx.svc, agent5_auth(), s.session_id)
	testing.expect(t, ok, "the conversion should succeed")
	// The foreground -> background flip is the path most likely to grow a second
	// message, since it is the moment the run becomes notifiable.
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)

	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)
}

// --- AC5: the marker lands in the triggering conversation and nowhere else ------

@(test)
test_req5_marker_only_in_triggering_conversation :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)
	// The other agent's conversation exists and is reachable through the same fake
	// repository, so an accidental fan-out would land here. It must stay empty.
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_B), 0)
	testing.expect_value(t, len(fx.content.messages), 1)
}

// AC5's other half: the conversation is resolved from the TOKEN, so naming somebody
// else's conversation in the request body cannot redirect the marker.
@(test)
test_req5_body_cannot_redirect_the_marker :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	session, _, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id       = "brg_1",
		kind            = domain.Shell_Session_Kind_Run,
		cmd             = "echo hi",
		background      = true,
		conversation_id = CONV_B, // another agent's conversation, asked for explicitly
	})
	testing.expect(t, session.session_id != "", "the run should still be created")
	testing.expect_value(t, session.conversation_id, CONV_A)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_B), 0)
	testing.expect_value(t, c5_markers_in(&fx.content, CONV_A), 1)
}

// --- AC6 + AC7: the marker is lean, and carries no output ----------------------

@(test)
test_req5_marker_is_lean :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	session, _, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id  = "brg_1",
		kind       = domain.Shell_Session_Kind_Run,
		cmd        = "echo SECRET_OUTPUT_MARKER",
		background = true,
	})
	m, found := c5_first_marker(&fx.content)
	testing.expect(t, found, "a marker should have been written")

	testing.expect_value(t, m.message_type, "shell_run")
	testing.expect_value(t, m.conversation_id, CONV_A)

	// AC6: metadata_json is the session id and NOTHING else. Asserted as an exact
	// string rather than by substring, because "contains the session id" would pass
	// just as well for a metadata blob that had quietly grown a status or an exit code.
	expected := strings.concatenate({`{"session_id":"`, session.session_id, `"}`}, context.temp_allocator)
	testing.expect_value(t, m.metadata_json, expected)

	// AC6: the body carries no output, no exit code and no command text.
	testing.expect_value(t, m.body, content_service.SHELL_RUN_MARKER_BODY)
	testing.expect(t, !strings.contains(m.body, "SECRET_OUTPUT_MARKER"), "the body must not carry the command")

	// AC7: nothing anywhere in the stored message carries the command or its output —
	// body and metadata both. Output never reaches the hub DB by this path.
	testing.expect(t, !strings.contains(m.metadata_json, "SECRET_OUTPUT_MARKER"), "metadata must not carry the command")
	testing.expect(t, !strings.contains(m.body, "echo"), "the body must not carry command text")
}

// AC7's other half: the NOTIFICATION carries no output either. It is the only other
// thing this requirement adds that travels off the exit path.
@(test)
test_req5_notification_carries_no_output :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	s := fx5_start_run(&fx, true)
	_ = shell_session_handle_exited(&fx.svc, s.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)

	body, found := s5_notify_body(&fx.sink, s.session_id)
	testing.expect(t, found, "a notification should have been sent")
	testing.expect(t, !strings.contains(body, "output"), "the notification must carry no output field")
	testing.expect(t, !strings.contains(body, "echo hi"), "the notification must carry no command text")
}

// --- scope guards: only a `run` does either of these ---------------------------
//
// Not decoration. Both gates are single conditions that a later edit could widen
// without any other test noticing, and widening either would put a server's lifecycle
// into an agent's transcript — the fan-out REQ-SHELL-5 §2 exists to prevent.

@(test)
test_req5_server_gets_no_marker_and_no_notification :: proc(t: ^testing.T) {
	fx: Fx5
	fx5_make(&fx)
	defer fx5_free(&fx)

	session, ok, _ := shell_session_create(&fx.svc, agent5_auth(), Shell_Session_Create_Input{
		bridge_id = "brg_1",
		kind      = domain.Shell_Session_Kind_Server,
		cmd       = "python3 -m http.server",
		chain_id  = "chain_1",
	})
	testing.expect(t, ok, "a server is startable by an agent")
	testing.expect_value(t, len(fx.content.messages), 0)

	_ = shell_session_handle_exited(&fx.svc, session.session_id, "brg_1", domain.Shell_Session_Status_Exited, 0, true)
	testing.expect_value(t, s5_notify_count(&fx.sink, session.session_id), 0)
}
