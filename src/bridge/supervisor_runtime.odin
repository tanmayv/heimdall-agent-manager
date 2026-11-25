package main

// A converted (supervisor-managed) instance after conversion: conversion spec §12.
//   - which executable is "this profile's Bridge" for status/stop (releases/<T>/bin, not bin/);
//   - the one predicate that switches the legacy updater off (bridge_convert_supervisor_managed:
//     valid instance.json and launcher/ham-launcher);
//   - hub-started updates and the hub's update channel, both delivered to the supervisor as
//     intents (engine spec §10) instead of running the legacy `ham-bridge update`.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import lc "odin_test:launcher/core"
import bridgesvc "odin_test:lib/bridgesvc"
import "odin_test:supervisor/service"

BRIDGE_SUPERVISOR_INTENT_TTL_S :: 3600

// bridge_managed_layout fills the Windows task name of a supervisor-managed instance
// (the converted task is "<service>-<h12>", not "\<service>; conversion spec §10.3).
bridge_managed_layout :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> bridgesvc.Layout {
	out := l
	if l.backend != .Schtasks || l.task_name != "" || !bridge_convert_supervisor_managed(host, l) do return out
	rec, reason := lc.read_instance_record(l.data_dir, context.temp_allocator)
	if reason != "" do return out
	out.task_name = bridgesvc.windows_task_name(l.service_name, bridge_convert_windows_sid(), rec.instance_id)
	return out
}

// bridge_runtime_images: the executables that may be this profile's running Bridge.
// A managed instance runs from releases/<current|previous>/bin (a mid-activation window may
// still show the previous tree, §12.1); a legacy one from bin/.
bridge_runtime_images :: proc(host: bridgesvc.Host, l: bridgesvc.Layout) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if bridge_convert_supervisor_managed(host, l) {
		for pointer in ([]string{lc.POINTER_CURRENT, lc.POINTER_PREVIOUS}) {
			tree, ok := lc.read_pointer(l.data_dir, pointer)
			if !ok || tree == "" do continue
			image := bridgesvc.tree_bin_path(host, l, tree, "ham-bridge")
			dup := false
			for have in out do if have == image do dup = true
			if !dup do append(&out, image)
		}
		return out[:]
	}
	append(&out, bridgesvc.pjoin(l.bin_dir, bridgesvc.exe_name(host, "ham-bridge")))
	return out[:]
}

// bridge_own_layout resolves the layout this running Bridge was installed as; managed is
// whether the supervisor owns it. ok = false for a Bridge that is not a registered service.
bridge_own_layout :: proc() -> (host: bridgesvc.Host, l: bridgesvc.Layout, managed: bool, ok: bool) {
	host = bridge_service_host()
	name, registered := bridge_enroll_service_for(host, os.args)
	if !registered || !strings.has_prefix(name, bridgesvc.SERVICE_PREFIX) do return
	l = bridgesvc.layout_for(host, name)
	return host, l, bridge_convert_supervisor_managed(host, l), true
}

// bridge_hub_op_id derives the intent id from the hub's command id, so a re-sent command is
// the same intent (engine §10). Only [A-Za-z0-9_-] survive; "op_" + at most 61 characters.
bridge_hub_op_id :: proc(command_id: string, now: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "op_hub_")
	n := 0
	for c in transmute([]byte)command_id {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
			if len(b.buf) < service.MAX_OP_ID_LEN {
				strings.write_byte(&b, c)
				n += 1
			}
		}
	}
	if n == 0 do fmt.sbprintf(&b, "%d", now)
	return strings.to_string(b)
}

// bridge_supervisor_submit writes one intent for the managed instance at l ("" = queued).
bridge_supervisor_submit :: proc(l: bridgesvc.Layout, it: service.Intent, now: i64) -> string {
	rec, reason := lc.read_instance_record(l.data_dir, context.temp_allocator)
	if reason != "" do return fmt.tprintf("instance.json: %s", reason)
	it := it
	it.instance_id = rec.instance_id
	it.created_at = now
	it.expires_at = now + BRIDGE_SUPERVISOR_INTENT_TTL_S
	if reason := service.validate_intent(it, true, rec.instance_id, now); reason != "" do return fmt.tprintf("the supervisor would refuse this intent (%s)", reason)
	return service.submit_intent(l.data_dir, it)
}

// bridge_supervisor_update_intent: the hub's update command -> install_version (an explicit
// version, also for allow_downgrade; engine §13.2 decides) or update_now when it names none.
// The hub never supplies a URL (REQ-SRC-1): the supervisor resolves and verifies the release.
bridge_supervisor_update_intent :: proc(l: bridgesvc.Layout, command_id, target_version, actor: string, now: i64) -> (op_id: string, err: string) {
	it := service.Intent{op_id = bridge_hub_op_id(command_id, now), actor = actor, action = "update_now"}
	if v := strings.trim_space(target_version); v != "" && v != "latest" {
		tag, _, ok := service.tag_version(v)
		if !ok do return "", fmt.tprintf("target version %q is not a release tag (vX.Y.Z)", v)
		it.action, it.version = "install_version", tag
	}
	if err = bridge_supervisor_submit(l, it, now); err != "" do return "", err
	return it.op_id, ""
}

// bridge_supervisor_channel_intent submits set_channel when update.json differs from the hub's
// channel (queued = true). op_id carries the stored revision: re-sending before the supervisor
// applied it replaces the same file, applying it bumps the revision, so a later hub push of the
// other channel is a new intent.
bridge_supervisor_channel_intent :: proc(l: bridgesvc.Layout, channel: string, now: i64) -> (queued: bool, err: string) {
	if channel != "stable" && channel != "fast" do return false, fmt.tprintf("unknown channel %q", channel)
	settings := service.read_settings(l.state_dir)
	if settings.channel == channel do return false, ""
	it := service.Intent{op_id = fmt.tprintf("op_hubchan_%s_%d", channel, settings.revision), actor = "hub:channel", action = "set_channel", channel = channel}
	if err = bridge_supervisor_submit(l, it, now); err != "" do return false, err
	return true, ""
}

// The hub pushes its update channel in bridge_ready (stable | fast). Applied on a thread of
// its own: resolving the service can run the service manager.
bridge_hub_update_channel_pending: string
bridge_hub_update_channel_mutex: sync.Mutex

bridge_hub_apply_update_channel :: proc(channel: string) {
	if channel == "" do return
	sync.mutex_lock(&bridge_hub_update_channel_mutex)
	delete(bridge_hub_update_channel_pending)
	bridge_hub_update_channel_pending = strings.clone(channel)
	sync.mutex_unlock(&bridge_hub_update_channel_mutex)
	thread.run(bridge_hub_update_channel_worker)
}

bridge_hub_update_channel_worker :: proc() {
	sync.mutex_lock(&bridge_hub_update_channel_mutex)
	channel := strings.clone(bridge_hub_update_channel_pending, context.temp_allocator)
	sync.mutex_unlock(&bridge_hub_update_channel_mutex)
	_, l, managed, ok := bridge_own_layout()
	if !ok || !managed do return // a legacy instance has no channel: only the supervisor reads it
	queued, err := bridge_supervisor_channel_intent(l, channel, time.to_unix_seconds(time.now()))
	if err != "" {
		fmt.printfln("bridge hub runtime: cannot apply the hub update channel %s: %s", channel, err)
	} else if queued {
		fmt.printfln("bridge hub runtime: hub update channel is %s; asked the supervisor to follow it", channel)
	}
	free_all(context.temp_allocator)
}

// bridge_managed_request_stop asks a managed instance's launcher to stop gracefully, from any
// session (engine §7.3): the request file the launcher polls. Best effort.
bridge_managed_request_stop :: proc(l: bridgesvc.Layout) {
	rec, reason := lc.read_instance_record(l.data_dir, context.temp_allocator)
	if reason != "" do return
	path := bridgesvc.launcher_stop_request_path(l)
	_ = os.make_directory_all(bridgesvc.pdir(path))
	_ = bridge_retry_atomic_write(path, transmute([]byte)bridgesvc.render_launcher_stop_request(rec.instance_id, time.to_unix_seconds(time.now())))
}
