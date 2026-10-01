package main

import "core:fmt"
import "core:strings"

// ── Local plaintext caps for vault-encrypted agent text (REQ-VCAP-4) ─────────
//
// ctl encrypts chain titles/descriptions before sending them (see
// vault_content.odin), so the Hub only ever sees the armored envelope and can
// bound its STORAGE size, never the plaintext length. The caller's real budget
// is the PLAINTEXT one, so ctl checks it here — before encrypting — and reports
// the overflow in the units the caller controls. The Hub keeps its own
// armor-aware checks as defence in depth for non-ctl clients.
//
// These MIRROR the authoritative constants in src/hub/domain (taskchain.odin:
// CHAIN_TITLE_MAX_BYTES / CHAIN_DESCRIPTION_MAX_BYTES). ctl does not import
// hub/domain — components mirror Hub domain values rather than depending on the
// Hub package (cf. src/bridge/bridge_shell_session.odin:25, which mirrors
// domain.Shell_Session_Kind the same way). Keep both sides in sync.
CTL_CHAIN_TITLE_MAX_BYTES       :: 120
CTL_CHAIN_DESCRIPTION_MAX_BYTES :: 4000

// ctl_check_plaintext_cap reports whether value fits its plaintext byte cap.
// On overflow it prints the standard agent-mode error envelope naming BOTH the
// actual plaintext length and the plaintext limit, so the caller knows exactly
// how much to cut, and returns false.
ctl_check_plaintext_cap :: proc(label: string, value: string, plaintext_max: int) -> bool {
	if len(value) <= plaintext_max do return true
	// The message is assembled with concatenate rather than printf'd as one
	// format string: Odin's fmt treats "{" as a verb delimiter, so the literal
	// JSON braces of the envelope get mangled into "%!(MISSING CLOSE BRACE)".
	// Same trap, same workaround as src/hub/service/push/webpush_vapid.odin:111.
	detail := fmt.tprintf(
		"%s is too long: %d bytes of plaintext, limit %d (checked before encryption)",
		label,
		len(value),
		plaintext_max,
	)
	fmt.println(strings.concatenate({`{"ok":false,"message":"`, detail, `"}`}, context.temp_allocator))
	return false
}
