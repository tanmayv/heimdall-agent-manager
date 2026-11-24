package bridgesvc

import "core:strings"
import "core:testing"

// T15 acceptance (report §7 Phase 1): ham-launcher and ham-supervisor ship in the bundle but
// are NOT the service entry point yet. Every service definition setup renders (systemd unit,
// LaunchAgent plist, Scheduled Task + run.cmd, runit run file) starts bin/ham-bridge and never
// names the launcher or the supervisor. Phase 2 changes this test together with the services.
@(test)
test_service_entry_point_is_still_ham_bridge :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for target in ([]Target_OS{.Linux, .Darwin, .Windows, .Termux}) {
		host := Host{os = target, home = "/home/u", appdata = "C:/Users/u/AppData/Roaming", local_appdata = "C:/Users/u/AppData/Local", prefix = "/data/usr", uid = 501}
		l := layout_for(host, "heimdall-bridge-hub-example-com")
		in_ := Render_Input{hub = "https://hub.example.com", windows_user = `HOST\u`, bridge_port = 49323, endpoint_port = 49324}
		args := service_args(host, l, in_)
		testing.expectf(t, strings.has_suffix(args[0], exe_name(host, "ham-bridge")), "%v: service runs %s", target, args[0])
		texts := [dynamic]string{}
		defer delete(texts)
		append(&texts, render_service_file(host, l, in_))
		if target == .Windows {
			append(&texts, render_windows_run_cmd(host, l, in_), render_windows_launcher(l))
		}
		// Windows: the task runs wscript run.vbs -> run.cmd -> ham-bridge.exe.
		all := strings.join(texts[:], "\n", context.temp_allocator)
		testing.expectf(t, strings.contains(all, exe_name(host, "ham-bridge")), "%v: service definition starts ham-bridge", target)
		for text in texts {
			testing.expectf(t, !strings.contains(text, "ham-launcher") && !strings.contains(text, "ham-supervisor"), "%v: service definition names the launcher or supervisor:\n%s", target, text)
		}
	}
}
