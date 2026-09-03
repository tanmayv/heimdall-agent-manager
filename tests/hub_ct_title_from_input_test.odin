package hub_ct_title_from_input_test

// PS-7 regression: the conversation title must NOT be derived from the initial
// message body. conversation_title_from_input seeds from an EXPLICIT title only,
// falling back to the given default (the per-run "<agent-name> #<n>" default).
// This keeps title_source=default so the activity-gated title-nudge engine can
// set a real title later, and avoids penalizing long first messages.

import "core:fmt"
import "core:os"
import "core:strings"
import content_service "odin_test:hub/service/content"

check :: proc(ok: bool, msg: string) { if ok do return; fmt.eprintln("FAIL:", msg); os.exit(1) }

main :: proc() {
	// A long first message must NOT become the title; with no explicit title we
	// fall through to the default ("<agent-name> #<n>" is passed as the fallback
	// by create_conversation).
	long_body := "Please investigate the flaky launch path and write up a detailed plan covering the wrapper, bridge, and hub so we can decide next steps before the release cutoff."
	default_title := "Reviewer #7"
	check(content_service.conversation_title_from_input("", default_title) == default_title,
		"no explicit title -> falls back to the per-run default, NEVER the initial message body")

	// The long body is never used as a seed, so its text must not appear.
	title_no_explicit := content_service.conversation_title_from_input("", default_title)
	check(!strings.contains(title_no_explicit, "investigate"),
		"initial body text must not leak into the title")

	// An EXPLICIT title still wins (normalized/whitespace-collapsed).
	check(content_service.conversation_title_from_input("  My   Chat  ", default_title) == "My Chat",
		"explicit title is honored (whitespace-normalized)")

	// Empty explicit + empty fallback -> empty (agent_service supplies the real
	// per-run default at the call site; this proc does not invent one).
	check(content_service.conversation_title_from_input("", "") == "",
		"empty explicit + empty fallback yields empty (caller supplies default)")

	fmt.println("PASS: conversation title is never derived from the initial message body (PS-7)")
}
