package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// REQ-SCHED-39 (spec SCHED 10.2): the bridge stores the pack_version beside
// TASK.md and sends it on `lease next`, so an unchanged pack is neither rebuilt
// by the hub nor rewritten here.

@(private = "file")
pack_version_test_dir :: proc(tag: string) -> string {
	return fmt.tprintf("%s/.cache/heimdall-tests/pack-version-%s-%d", os.get_env("HOME", context.temp_allocator), tag, time.to_unix_nanoseconds(time.now()))
}

PACK_VERSION_TEST_PACK :: `{"version":1,"lease_id":"lease_1","task_id":"task_1","phase":"active","task":{"task_id":"task_1","title":"T"},"lease":{"lease_id":"lease_1","kind":"work"}}`

@(test)
test_bridge_task_md_stores_and_sends_pack_version :: proc(t: ^testing.T) {
	dir := pack_version_test_dir("store")
	defer _ = os.remove_all(dir)
	// No TASK.md yet: nothing is sent.
	out, sent, injected := bridge_taskv2_inject_pack_version(`{"cwd":"/x"}`, dir)
	testing.expect(t, !injected && sent == "" && out == `{"cwd":"/x"}`, "no stored version without TASK.md")

	testing.expect(t, bridge_taskv2_materialize_task_md(dir, PACK_VERSION_TEST_PACK, pack_version = "pv1-aaaa"), "materialize")
	testing.expect_value(t, bridge_taskv2_stored_pack_version(dir), "pv1-aaaa")
	out, sent, injected = bridge_taskv2_inject_pack_version(`{"cwd":"/x"}`, dir)
	testing.expect(t, injected, "the stored version is sent")
	testing.expect_value(t, sent, "pv1-aaaa")
	testing.expect(t, strings.contains(out, `"pack_version":"pv1-aaaa"`) && strings.contains(out, `"cwd":"/x"`), out)
	if injected do delete(out)

	// A peek never carries a version (it needs the pack's placement).
	_, sent, injected = bridge_taskv2_inject_pack_version(`{"peek":true}`, dir)
	testing.expect(t, !injected && sent == "", "peek sends no version")
	// `ham-ctl lease next --refresh` sends an empty version: the caller's wins.
	out, sent, injected = bridge_taskv2_inject_pack_version(`{"pack_version":""}`, dir)
	testing.expect(t, !injected && sent == "" && out == `{"pack_version":""}`, "an explicit version is kept")

	// A pack written without a version (a wake) clears the stored one.
	testing.expect(t, bridge_taskv2_materialize_task_md(dir, PACK_VERSION_TEST_PACK), "materialize without version")
	testing.expect_value(t, bridge_taskv2_stored_pack_version(dir), "")
	testing.expect(t, bridge_taskv2_materialize_task_md(dir, PACK_VERSION_TEST_PACK, pack_version = "pv1-bbbb"), "materialize again")
	bridge_taskv2_store_pack_version(dir, "")
	testing.expect_value(t, bridge_taskv2_stored_pack_version(dir), "")
	// A version without TASK.md is never sent.
	bridge_taskv2_store_pack_version(dir, "pv1-cccc")
	_ = os.remove(fmt.tprintf("%s/TASK.md", dir))
	testing.expect_value(t, bridge_taskv2_stored_pack_version(dir), "")
}
