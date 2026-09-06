package push

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// --- WP-SEND-2: payload construction (mirrors notificationMapper.ts) ---------

@(test)
build_chat_notification_plain :: proc(t: ^testing.T) {
	c := build_chat_notification("conv_1", "inst_1", "text", "hello world")
	defer free_notification_content(c)
	testing.expect_value(t, c.title, "New message")
	testing.expect_value(t, c.body, "hello world")
	testing.expect_value(t, c.tag, "heimdall:chat:conv_1")
	testing.expect_value(t, c.route, "/conversations/conv_1")
	testing.expect_value(t, c.category, Push_Category.Chat)
}

@(test)
build_chat_notification_nudge_and_mention :: proc(t: ^testing.T) {
	n := build_chat_notification("conv_1", "inst_1", "nudge", "poke")
	defer free_notification_content(n)
	testing.expect_value(t, n.title, "Nudge")

	m := build_chat_notification("conv_1", "inst_1", "mention", "hey @you")
	defer free_notification_content(m)
	testing.expect_value(t, m.title, "You were mentioned")
}

@(test)
build_chat_notification_falls_back_to_instance :: proc(t: ^testing.T) {
	// No conversation id -> route + tag key on the agent instance id.
	c := build_chat_notification("", "inst_9", "text", "hi")
	defer free_notification_content(c)
	testing.expect_value(t, c.route, "/conversations/inst_9")
	testing.expect_value(t, c.tag, "heimdall:chat:inst_9")
}

@(test)
build_chat_notification_empty_ids_are_freeable :: proc(t: ^testing.T) {
	// Both ids empty -> static-looking fallbacks, but still heap-allocated so
	// free_notification_content is always safe (no delete() of a literal).
	c := build_chat_notification("", "", "text", "hi")
	defer free_notification_content(c)
	testing.expect_value(t, c.route, "/conversations")
	testing.expect_value(t, c.tag, "heimdall:chat:unknown")
}

@(test)
build_push_payload_json_shape_with_origin :: proc(t: ^testing.T) {
	c := Notification_Content{
		title = "New message",
		body = "hi there",
		tag = "heimdall:chat:conv_1",
		route = "/conversations/conv_1",
		category = .Chat,
	}
	got := build_push_payload_json(c, "https://heimdal.mundus.in")
	defer delete(got)
	// Field presence + the absolute href = origin + "/#" + route.
	testing.expect(t, strings.contains(got, "\"title\":\"New message\""))
	testing.expect(t, strings.contains(got, "\"category\":\"chat\""))
	testing.expect(t, strings.contains(got, "\"route\":\"/conversations/conv_1\""))
	testing.expect(t, strings.contains(got, "\"href\":\"https://heimdal.mundus.in/#/conversations/conv_1\""))
}

@(test)
build_push_payload_json_empty_href_without_origin :: proc(t: ^testing.T) {
	c := Notification_Content{title = "t", body = "b", tag = "g", route = "/conversations", category = .Attention}
	got := build_push_payload_json(c, "")
	defer delete(got)
	testing.expect(t, strings.contains(got, "\"href\":\"\""))
	testing.expect(t, strings.contains(got, "\"category\":\"attention\""))
}

@(test)
push_preview_truncates_on_rune_boundary :: proc(t: ^testing.T) {
	// Collapses whitespace.
	c := push_preview("  a\t\n b  ", 140)
	defer delete(c)
	testing.expect_value(t, c, "a b")

	// Truncates with an ellipsis at max_len.
	long := strings.repeat("x", 200)
	defer delete(long)
	trunc := push_preview(long, 10)
	defer delete(trunc)
	// 9 x's + ellipsis rune.
	testing.expect(t, strings.has_suffix(trunc, "\u2026"))
	testing.expect(t, strings.count(trunc, "x") == 9)
}

// --- WP-SEND-1: endpoint splitting + disabled no-op --------------------------

@(test)
split_endpoint_parses_base_and_path :: proc(t: ^testing.T) {
	base, path, ok := split_endpoint("https://web.push.apple.com/abc/def?x=1")
	defer delete(base); defer delete(path)
	testing.expect(t, ok)
	testing.expect_value(t, base, "https://web.push.apple.com")
	testing.expect_value(t, path, "/abc/def?x=1")

	base2, path2, ok2 := split_endpoint("https://fcm.googleapis.com")
	defer delete(base2); defer delete(path2)
	testing.expect(t, ok2)
	testing.expect_value(t, base2, "https://fcm.googleapis.com")
	testing.expect_value(t, path2, "/")

	_, _, bad := split_endpoint("not-a-url")
	testing.expect(t, !bad)
}

@(test)
send_to_user_noop_when_disabled :: proc(t: ^testing.T) {
	// A service with no VAPID keypair must not attempt any delivery.
	repo: iface.Push_Repository
	clock := platform.real_clock()
	ids := platform.real_id_generator()
	service := new_push_service(&repo, &clock, &ids) // empty Vapid_Config
	testing.expect(t, !push_send_enabled(&service))
	sent := send_to_user(&service, domain.User_ID("usr_1"), "{}")
	testing.expect_value(t, sent, 0)
}
