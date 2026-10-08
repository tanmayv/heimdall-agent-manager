package push

import "core:strings"
import "core:testing"

// --- REQ-IMPL-5 (Part A item 6): the post-approval enrollment notification ---

@(test)
enrollment_notification_is_attention_and_deep_links_to_bridges :: proc(t: ^testing.T) {
	content := build_enrollment_approval_notification("a1b2 c3d4 e5f6 0718")
	defer free_notification_content(content)

	testing.expect_value(t, content.category, Push_Category.Attention)
	testing.expect_value(t, content.route, "/settings/bridges")
	testing.expect_value(t, content.title, "Bridge enrollment approved")
	testing.expect(
		t,
		strings.contains(content.body, "a1b2 c3d4 e5f6 0718"),
		"the hub-computed fingerprint must be in the body so the owner can compare it",
	)
	testing.expect(
		t,
		strings.contains(content.body, "revoke"),
		"a notification about a possibly-unwanted approval must say what to do about it",
	)
}

@(test)
enrollment_notification_omits_the_fingerprint_rather_than_dangling :: proc(t: ^testing.T) {
	// An empty fingerprint must not render as "Key fingerprint ." — the detail
	// is dropped instead, so the notification never shows a label with nothing
	// after it.
	content := build_enrollment_approval_notification("")
	defer free_notification_content(content)

	testing.expect(t, !strings.contains(content.body, "fingerprint"), "empty fingerprint must be omitted entirely")
	testing.expect(t, len(content.body) > 0, "the notification still has to say something")
	testing.expect(t, strings.contains(content.body, "revoke"), "the call to action survives a missing fingerprint")
}

@(test)
enrollment_notification_tag_coalesces_repeats :: proc(t: ^testing.T) {
	// A FIXED tag is deliberate: a per-bridge tag would let an attacker who has
	// obtained one approval bury that notification under a burst of others.
	a := build_enrollment_approval_notification("a1b2 c3d4 e5f6 0718")
	defer free_notification_content(a)
	b := build_enrollment_approval_notification("ffff eeee dddd cccc")
	defer free_notification_content(b)

	testing.expect_value(t, a.tag, b.tag)
	testing.expect_value(t, a.tag, "heimdall:attention:bridge-enrollment")
}

@(test)
enrollment_payload_json_carries_the_attention_category_and_href :: proc(t: ^testing.T) {
	content := build_enrollment_approval_notification("a1b2 c3d4 e5f6 0718")
	defer free_notification_content(content)
	payload := build_push_payload_json(content, "https://heimdall.example/")
	defer delete(payload)

	testing.expect(t, strings.contains(payload, "\"category\":\"attention\""), payload)
	testing.expect(
		t,
		strings.contains(payload, "\"href\":\"https://heimdall.example/#/settings/bridges\""),
		payload,
	)
}

@(test)
enrollment_notification_carries_no_host_asserted_text :: proc(t: ^testing.T) {
	// THE POINT OF THIS TEST: a push notification is rendered by the operating
	// system, outside any page we control, so none of the approval screen's
	// bidi-stripping or mixed-script flagging applies to it. Putting a
	// host-asserted hostname in here would hand an attacker a spoofing surface
	// strictly better than the one REQ-ENROLL-6 just closed.
	//
	// The builder takes ONLY a fingerprint, so there is no parameter through
	// which host-asserted text could arrive. This test pins that signature: if
	// somebody later adds a `device_label` argument "to make the notification
	// more useful", this is what should stop them and explain why.
	content := build_enrollment_approval_notification("a1b2 c3d4 e5f6 0718")
	defer free_notification_content(content)

	// A hostname carrying an RLO override, as a crafted machine would send.
	hostile := "evil‮moc.elpmaxe"
	testing.expect(
		t,
		!strings.contains(content.body, hostile),
		"host-asserted text must not be reachable from this payload",
	)
	testing.expect(
		t,
		!strings.contains(content.body, "‮"),
		"no bidi control may appear in an OS-rendered notification",
	)
}
