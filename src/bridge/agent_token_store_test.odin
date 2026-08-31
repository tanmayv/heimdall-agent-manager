package main

import "core:os"
import "core:strings"
import "core:testing"

// Tests for per-bridge local-token store isolation + atomic persistence
// (task_18d0f1f7b6c80449): two bridges sharing one store used to clobber each
// other's tokens on full-file rewrite, leaving agents permanently unauthenticated
// on reconnect. The store is now namespaced by local_endpoint_run_dir.

@(test)
bridge_token_store_namespace_is_per_bridge :: proc(t: ^testing.T) {
	saved := bridge_config.local_endpoint_run_dir
	defer { bridge_config.local_endpoint_run_dir = saved }

	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local"
	a := bridge_agent_token_store_namespace()
	bridge_config.local_endpoint_run_dir = "/tmp/heimdall-bridge-local-macbook-remote"
	b := bridge_agent_token_store_namespace()
	testing.expect(t, a != b, "distinct run dirs must yield distinct namespaces")
	testing.expect(t, !strings.contains(a, "/"), "namespace must be a single safe path segment")
	testing.expect(t, !strings.contains(b, "/"), "namespace must be a single safe path segment")

	bridge_config.local_endpoint_run_dir = ""
	testing.expect(t, bridge_agent_token_store_namespace() == "default", "empty run dir -> default namespace")
}

@(test)
bridge_token_store_two_bridges_do_not_clobber :: proc(t: ^testing.T) {
	saved_dir := bridge_config.local_endpoint_run_dir
	saved_data := bridge_config.data_dir
	defer {
		bridge_config.local_endpoint_run_dir = saved_dir
		bridge_config.data_dir = saved_data
	}
	// Isolate to a scratch data dir so we never touch a real store.
	scratch := "/tmp/ham-token-store-test"
	bridge_config.data_dir = scratch

	// Bridge A issues a token.
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeA"
	bridge_agent_token_store_init()
	issue_a := bridge_agent_token_issue("inst_A", "hit_inst_A", .Wrapper)
	rec_a, ok_a := bridge_agent_token_verify(issue_a.plaintext_token)
	testing.expect(t, ok_a && rec_a.agent_instance_id == "inst_A", "bridge A token verifies after issue")

	// Bridge B (different run dir) issues its own token; this MUST NOT wipe A.
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeB"
	bridge_agent_token_store_init() // reloads B's (separate) store into memory
	_ = bridge_agent_token_issue("inst_B", "hit_inst_B", .Wrapper)

	// Reload bridge A's store from disk; its token must still be present.
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeA"
	bridge_agent_token_store_init()
	rec_a2, ok_a2 := bridge_agent_token_verify(issue_a.plaintext_token)
	testing.expect(t, ok_a2 && rec_a2.agent_instance_id == "inst_A", "bridge A token SURVIVES bridge B issuing its own token")

}

@(test)
bridge_token_store_save_load_roundtrip :: proc(t: ^testing.T) {
	saved_dir := bridge_config.local_endpoint_run_dir
	saved_data := bridge_config.data_dir
	defer {
		bridge_config.local_endpoint_run_dir = saved_dir
		bridge_config.data_dir = saved_data
	}
	bridge_config.data_dir = "/tmp/ham-token-store-rt"
	bridge_config.local_endpoint_run_dir = "/tmp/bridgeRT"

	bridge_agent_token_store_init()
	issue := bridge_agent_token_issue("inst_RT", "hit_inst_RT", .Agent)

	// Fresh init reloads from disk (atomic-written file) and still verifies.
	bridge_agent_token_store_init()
	rec, ok := bridge_agent_token_verify(issue.plaintext_token)
	testing.expect(t, ok && rec.agent_instance_id == "inst_RT" && rec.role == .Agent, "token roundtrips through atomic save + reload")

}
