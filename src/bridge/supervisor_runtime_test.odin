package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import bridgesvc "odin_test:lib/bridgesvc"
import "odin_test:supervisor/service"

// A managed layout under a throwaway dir: valid instance.json (textual roots) + launcher file.
managed_fixture :: proc(t: ^testing.T, label: string) -> (host: bridgesvc.Host, l: bridgesvc.Layout, ok: bool) {
	root := fmt.tprintf("%s/ham-supervisor-runtime-%d-%s", os.get_env("TMPDIR", context.temp_allocator) if os.get_env("TMPDIR", context.temp_allocator) != "" else "/tmp", os.get_pid(), label)
	_ = os.remove_all(root)
	host = bridgesvc.Host{os = .Linux, uid = 0, home = root}
	l = bridgesvc.layout_for(host, "heimdall-bridge-test")
	_ = os.make_directory_all(l.data_dir)
	_ = os.make_directory_all(l.state_dir)
	_ = os.make_directory_all(bridgesvc.pjoin(l.data_dir, "launcher"))
	_ = os.write_entire_file(bridgesvc.launcher_path(host, l), []byte{'x'})
	uid := -1
	when ODIN_OS != .Windows {
		uid = int(posix.getuid())
		host.uid = uid
	}
	rec := fmt.tprintf(`{{"schema":1,"instance_id":"ins_0123456789abcdef0123456789abcdef","owner":{{"uid":%d,"sid":""}},"data_root":"%s","state_root":"%s"}}`, uid, l.data_dir, l.state_dir)
	ok = os.write_entire_file(bridgesvc.pjoin(l.data_dir, "instance.json"), transmute([]byte)rec) == nil
	return
}

@(test)
test_hub_op_id_is_stable_and_valid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := bridge_hub_op_id("cmd_upd_abc-123", 100)
	testing.expect_value(t, a, "op_hub_cmd_upd_abc-123")
	testing.expect_value(t, bridge_hub_op_id("cmd_upd_abc-123", 999), a) // re-sent command = same intent
	testing.expect(t, service.valid_op_id(bridge_hub_op_id(strings.repeat("x", 200, context.temp_allocator), 1)))
	testing.expect_value(t, bridge_hub_op_id("", 77), "op_hub_77")
	testing.expect_value(t, bridge_hub_op_id("a b/c", 1), "op_hub_abc")
}

@(test)
test_managed_runtime_images_and_channel_intent :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// The owner check of instance.json is a POSIX uid here; Windows uses a SID (covered by CI's
	// conversion tests), so this fixture is POSIX only.
	when ODIN_OS == .Windows do return
	host, l, ok := managed_fixture(t, "images")
	if !ok do return
	defer os.remove_all(host.home)
	managed := bridge_convert_supervisor_managed(host, l)
	if !managed { testing.expect(t, false, "fixture should be managed (instance.json + launcher)"); return }

	// No pointers yet: nothing can match. Legacy (no instance.json) expects bin/ham-bridge.
	testing.expect_value(t, len(bridge_runtime_images(host, l)), 0)
	legacy := l
	legacy.data_dir = bridgesvc.pjoin(l.data_dir, "nope")
	imgs := bridge_runtime_images(host, legacy)
	testing.expect_value(t, len(imgs), 1)
	testing.expect_value(t, imgs[0], bridgesvc.pjoin(legacy.bin_dir, "ham-bridge"))

	// hub channel -> set_channel intent -> parsed by the supervisor's own validator.
	queued, err := bridge_supervisor_channel_intent(l, "fast", 1_000_000)
	testing.expect_value(t, err, "")
	testing.expect(t, queued)
	inbox := bridgesvc.pjoin(l.data_dir, "supervisor", "intents", "inbox")
	data, rerr := os.read_entire_file(bridgesvc.pjoin(inbox, "op_hubchan_fast_0.json"), context.temp_allocator)
	testing.expect(t, rerr == nil)
	it, status, schema_ok := service.parse_intent(data)
	testing.expect(t, status == .Ok)
	testing.expect_value(t, it.action, "set_channel")
	testing.expect_value(t, it.channel, "fast")
	testing.expect_value(t, service.validate_intent(it, schema_ok, "ins_0123456789abcdef0123456789abcdef", 1_000_000), "")

	// Channel already in update.json (the default is stable): no intent. Unknown channel: refused.
	queued, err = bridge_supervisor_channel_intent(l, "stable", 1_000_000)
	testing.expect(t, !queued && err == "")
	queued, err = bridge_supervisor_channel_intent(l, "nightly", 1_000_000)
	testing.expect(t, !queued && err != "")

	// hub update -> install_version (explicit tag, also for a downgrade) / update_now.
	op, uerr := bridge_supervisor_update_intent(l, "cmd_upd_1", "0.5.86", "hub:update", 1_000_000)
	testing.expect_value(t, uerr, "")
	testing.expect_value(t, op, "op_hub_cmd_upd_1")
	data, _ = os.read_entire_file(bridgesvc.pjoin(inbox, "op_hub_cmd_upd_1.json"), context.temp_allocator)
	it, _, schema_ok = service.parse_intent(data)
	testing.expect_value(t, it.action, "install_version")
	testing.expect_value(t, it.version, "v0.5.86")
	_, uerr = bridge_supervisor_update_intent(l, "cmd_upd_2", "latest", "hub:update", 1_000_000)
	testing.expect_value(t, uerr, "")
	data, _ = os.read_entire_file(bridgesvc.pjoin(inbox, "op_hub_cmd_upd_2.json"), context.temp_allocator)
	it, _, _ = service.parse_intent(data)
	testing.expect_value(t, it.action, "update_now")
	_, uerr = bridge_supervisor_update_intent(l, "cmd_upd_3", "http://evil/x.tgz", "hub:update", 1_000_000)
	testing.expect(t, uerr != "", "the hub never supplies a URL")
}
