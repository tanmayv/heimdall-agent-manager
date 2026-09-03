// TEST-1 harness: drives the REAL bridge bootstrap code path against a LIVE local
// hub to prove cache HIT vs hub FETCH, capturing the exact log lines.
//
// Usage:
//   e2e_bridge_bootstrap_cache_harness <hub_url> <bridge_token> <agent_id> <cache_dir> <phase>
// phase in {cold, warm, after_memory}. Each invocation runs ONE conditional
// manifest fetch + per-hash blob resolution against the shared on-disk cache_dir,
// so running cold->warm->after_memory in sequence against the same cache_dir
// reproduces TEST-1 (1)(2)(3). The bridge's own stdout logs
// ("manifest HIT (304)"/"MISS (200)", "blob HIT (disk)"/"FETCH (hub)") are the
// acceptance signal.
package e2e_bridge_bootstrap_cache_harness

import "core:fmt"
import "core:os"
import "core:strings"
import bridge "odin_test:bridge"

main :: proc() {
	args := os.args
	if len(args) < 6 {
		fmt.eprintln("usage: harness <hub_url> <bridge_token> <agent_id> <cache_dir> <phase>")
		os.exit(2)
	}
	hub_url := args[1]
	bridge_token := args[2]
	agent_id := args[3]
	cache_dir := args[4]
	phase := args[5]

	cache: bridge.Bootstrap_Cache
	bridge.bootstrap_cache_init(&cache, cache_dir, 64 * 1024 * 1024)

	d := bridge.Bridge_Bootstrap_Descriptor{
		instance_id = "inst_e2e",
		agent_id    = agent_id,
		agent_name  = "E2E Agent",
		role        = "worker",
		provider    = "claude",
		project_id  = "",
	}

	fmt.println("=== PHASE", phase, "===")
	manifest_json, res := bridge.bridge_bootstrap_conditional_manifest(hub_url, bridge_token, "claude", d, &cache)
	if !res.ok {
		fmt.eprintln("FAIL: conditional manifest failed stage=", res.stage, "http_status=", res.http_status, "detail=", res.detail)
		os.exit(1)
	}
	defer delete(manifest_json)

	// Assemble AGENTS.md the same way the bridge does, to prove the memory shows up
	// in phase after_memory.
	agents_md, asm_ok := bridge.bridge_bootstrap_assemble_agents_md(manifest_json, d, &cache)
	if !asm_ok {
		fmt.eprintln("FAIL: assemble AGENTS.md failed")
		os.exit(1)
	}
	defer delete(agents_md)
	has_memory := strings.contains(agents_md, "Always cite the run id.")
	fmt.println("RESULT phase=", phase, "agents_md_bytes=", len(agents_md), "contains_new_memory=", has_memory)
	fmt.println("=== END", phase, "===")
}
