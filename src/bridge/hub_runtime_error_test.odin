package main

import "core:strings"
import "core:testing"

@(test)
hub_runtime_bridge_error_preserves_hub_diagnostic :: proc(t: ^testing.T) {
	message := bridge_hub_error_log_message(
		`{"type":"bridge_error","protocol_version":1,"payload":{"message":"provider catalog unavailable"}}`,
	)
	defer delete(message)
	testing.expect(
		t,
		strings.contains(message, "provider catalog unavailable"),
		"bridge log preserves the Hub's actual setup error",
	)
	testing.expect(
		t,
		!strings.contains(message, "token rejected"),
		"post-authentication setup errors are not mislabeled as token rejection",
	)
}

@(test)
hub_runtime_bridge_error_without_message_has_safe_fallback :: proc(t: ^testing.T) {
	message := bridge_hub_error_log_message(`{"type":"bridge_error","payload":{}}`)
	defer delete(message)
	testing.expect(
		t,
		strings.contains(message, "without a diagnostic message"),
		"malformed Hub errors retain an actionable fallback",
	)
}
