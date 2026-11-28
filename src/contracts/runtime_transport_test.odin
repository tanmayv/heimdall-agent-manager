package contracts

import "core:testing"

// Send now's needs are runtime data: every valid transport declares them, and
// an unknown transport supports nothing.
@(test)
runtime_transport_capabilities_declare_send_now :: proc(t: ^testing.T) {
	testing.expect(t, runtime_transport_capabilities("acp").send_now == .Members, "ACP delivers bodies: explicit members")
	testing.expect(t, runtime_transport_capabilities("pty").send_now == .Notice, "PTY reads its conversation: no members")
	testing.expect(t, runtime_transport_capabilities("tmux").send_now == .Unsupported)
	testing.expect(t, runtime_transport_capabilities("").send_now == .Unsupported)
	for name in ([]string{"pty", "acp"}) {
		testing.expect(t, runtime_transport_valid(name) && runtime_transport_capabilities(name).send_now != .Unsupported, name)
	}
	testing.expect_value(t, RUNTIME_SEND_NOW_WIRE[.Members], "members")
	testing.expect_value(t, RUNTIME_SEND_NOW_WIRE[.Notice], "notice")
}
