package bridge_runtime

import "core:fmt"
import "core:strings"
import "core:testing"
import project "odin_test:hub/service/project"

@(test)
runtime_results_obey_bridge_and_global_byte_budgets :: proc(t: ^testing.T) {
	r := new(project.Bridge_Runtime_Registry)
	defer { runtime_command_cache_destroy(r); free(r) }
	payload := strings.repeat("x", 2 * 1024 * 1024)
	defer delete(payload)
	for bridge in 0..<20 {
		for command in 0..<6 {
			_, _ = runtime_command_result_idempotent(r, fmt.tprintf("bridge_%d", bridge), 1, fmt.tprintf("cmd_%d", command), payload)
			total, same := 0, 0
			for i in 0..<r.command_slots_used {
				total += len(r.command_results_json[i])
				if r.command_bridge_ids[i] == fmt.tprintf("bridge_%d", bridge) do same += len(r.command_results_json[i])
			}
			testing.expect(t, total <= RUNTIME_RESULT_GLOBAL_BYTES)
			testing.expect(t, same <= RUNTIME_RESULT_BRIDGE_BYTES)
		}
	}
}
