package http

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

// REQ-VAULT-HARDEN-3: Hub passes unseal payload through and serializes public key.
@(test)
test_write_bridge_json_public_key_fields :: proc(t: ^testing.T) {
	registry: project_service.Bridge_Runtime_Registry
	project_service.bridge_runtime_registry_set_public_key(&registry, "brg_pk_test", "04aabbccddeeff")

	bridge := domain.Bridge{
		bridge_id = "brg_pk_test",
		label = "Worker Public Key",
		machine_hostname = "worker-pk",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = "{}",
		version = "0.2.0",
		commit_sha = "796bfb57",
		build_timestamp = "2026-10-01T12:00:00Z",
		update_status = "idle",
		update_error = "",
		last_seen_at = "2026-10-01T12:01:00Z",
		updated_at = "2026-10-01T12:01:00Z",
	}

	agents := agent_service.Agent_Service{
		bridge_runtime_registry = &registry,
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, &agents, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"public_key\":\"04aabbccddeeff\""), "public_key serialized from registry")
	testing.expect(t, strings.contains(out, "\"bridge_public_key\":\"04aabbccddeeff\""), "bridge_public_key serialized from registry")
}

// Fallback to capabilities_json if registry is empty
@(test)
test_write_bridge_json_public_key_from_capabilities :: proc(t: ^testing.T) {
	bridge := domain.Bridge{
		bridge_id = "brg_cap_test",
		label = "Worker Cap",
		machine_hostname = "worker-cap",
		machine_os = "linux",
		machine_arch = "amd64",
		hub_url = "http://127.0.0.1:8080",
		status = .Online,
		capabilities_json = `{"public_key":"04112233445566"}`,
		version = "0.2.0",
		commit_sha = "796bfb57",
		build_timestamp = "2026-10-01T12:00:00Z",
		update_status = "idle",
		update_error = "",
		last_seen_at = "2026-10-01T12:01:00Z",
		updated_at = "2026-10-01T12:01:00Z",
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_bridge_json(&b, bridge, nil, nil)
	out := strings.to_string(b)

	testing.expect(t, strings.contains(out, "\"public_key\":\"04112233445566\""), "public_key serialized from capabilities_json")
	testing.expect(t, strings.contains(out, "\"bridge_public_key\":\"04112233445566\""), "bridge_public_key serialized from capabilities_json")
}
