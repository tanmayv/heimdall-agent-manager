package main

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"

// REQ-BUPD-1: bridge_hub_hello_json includes version, commit_sha, built_at, and target.
@(test)
test_bridge_hub_hello_version_fields :: proc(t: ^testing.T) {
	hello := bridge_hub_hello_json()
	defer delete(hello)

	testing.expect(t, strings.contains(hello, "\"type\":\"bridge_hello\""), "type is bridge_hello")
	testing.expect(t, strings.contains(hello, "\"protocol_version\":1"), "protocol_version is 1")
	expected_version := fmt.tprintf("\"version\":\"%s\"", contracts.APP_VERSION)
	testing.expect(t, strings.contains(hello, expected_version), "version serialized from contracts")
	testing.expect(t, strings.contains(hello, "\"commit_sha\":\""), "commit_sha key present")
	testing.expect(t, strings.contains(hello, "\"built_at\":\""), "built_at key present")
	testing.expect(t, strings.contains(hello, "\"target\":\""), "target key present")

	target := bridge_target_string()
	expected_target := fmt.tprintf("\"target\":\"%s\"", target)
	testing.expect(t, strings.contains(hello, expected_target), "target matches host os and arch")
}
