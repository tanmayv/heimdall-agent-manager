package bridgesvc

import "core:strings"
import "core:testing"

// Golden tests: the legacy (unconverted) rendering must stay byte-identical, and the
// converted layout (conversion spec §7, §8.1, §10; engine §17) is checked on all three
// service backends.

@(private="file")
GOLD_NAME :: "heimdall-bridge-hub-example-com_work"

@(private="file")
gold_input :: proc() -> Render_Input {
	return Render_Input{hub = "https://hub.example.com", profile = "work", path_env = "/usr/bin:/bin", windows_user = `HOST\u`, bridge_port = 49325, endpoint_port = 49326}
}

@(private="file")
gold_hosts :: proc() -> (linux, mac, win: Host) {
	return Host{os = .Linux, home = "/home/u"}, Host{os = .Darwin, home = "/Users/u"}, Host{os = .Windows, appdata = "C:/R", local_appdata = "C:/L"}
}

@(test)
test_legacy_render_golden :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	linux, mac, win := gold_hosts()
	in_ := gold_input()
	wl := layout_for(win, GOLD_NAME)
	testing.expect_value(t, render_service_file(linux, layout_for(linux, GOLD_NAME), in_), GOLD_SYSTEMD)
	testing.expect_value(t, render_service_file(mac, layout_for(mac, GOLD_NAME), in_), GOLD_LAUNCHD)
	testing.expect_value(t, render_service_file(win, wl, in_), GOLD_TASK)
	testing.expect_value(t, render_windows_run_cmd(win, wl, in_), GOLD_RUN_CMD)
	testing.expect_value(t, render_windows_launcher(wl), GOLD_RUN_VBS)
}

@(private="file") GOLD_SYSTEMD := "[Unit]\nDescription=Ninjy Bridge https://hub.example.com (profile work)\nAfter=network-online.target\n\n[Service]\nType=simple\nExecStart=\"/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-bridge\" \"--hub\" \"https://hub.example.com\" \"--config\" \"/home/u/.config/heimdall/bridges/heimdall-bridge-hub-example-com_work/config.toml\" \"--bridge-token-file\" \"/home/u/.config/heimdall/bridges/heimdall-bridge-hub-example-com_work/bridge-token\" \"--data-dir\" \"/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work\" \"--bind-host\" \"127.0.0.1\" \"--port\" \"49325\" \"--local-endpoint-port\" \"49326\" \"--local-run-dir\" \"/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/run\"\nEnvironment=\"PATH=/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin:/usr/bin:/bin\"\nEnvironment=\"HEIMDALL_HAM_PTY_HOST_BIN=/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-pty-host\"\nEnvironment=\"HEIMDALL_BRIDGE_PTY_HOST=true\"\nEnvironment=\"HEIMDALL_HAM_CTL_BIN=/home/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-ctl\"\nEnvironment=\"HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:49326\"\nEnvironment=\"HEIMDALL_BRIDGE_SERVICE_NAME=heimdall-bridge-hub-example-com_work.service\"\nRestart=on-failure\nRestartSec=5\nKillMode=process\n\n[Install]\nWantedBy=default.target\n"
@(private="file") GOLD_LAUNCHD := "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n	<key>AbandonProcessGroup</key>\n	<true/>\n	<key>EnvironmentVariables</key>\n	<dict>\n		<key>HEIMDALL_BRIDGE_ENDPOINT</key>\n		<string>tcp:127.0.0.1:49326</string>\n		<key>HEIMDALL_BRIDGE_PTY_HOST</key>\n		<string>true</string>\n		<key>HEIMDALL_BRIDGE_SERVICE_NAME</key>\n		<string>heimdall-bridge-hub-example-com_work</string>\n		<key>HEIMDALL_HAM_CTL_BIN</key>\n		<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-ctl</string>\n		<key>HEIMDALL_HAM_PTY_HOST_BIN</key>\n		<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-pty-host</string>\n		<key>PATH</key>\n		<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin:/usr/bin:/bin</string>\n	</dict>\n	<key>KeepAlive</key>\n	<dict>\n		<key>SuccessfulExit</key>\n		<false/>\n	</dict>\n	<key>Label</key>\n	<string>heimdall-bridge-hub-example-com_work</string>\n	<key>ProgramArguments</key>\n	<array>\n		<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-bridge</string>\n		<string>--hub</string>\n		<string>https://hub.example.com</string>\n		<string>--config</string>\n		<string>/Users/u/.config/heimdall/bridges/heimdall-bridge-hub-example-com_work/config.toml</string>\n		<string>--bridge-token-file</string>\n		<string>/Users/u/.config/heimdall/bridges/heimdall-bridge-hub-example-com_work/bridge-token</string>\n		<string>--data-dir</string>\n		<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work</string>\n		<string>--bind-host</string>\n		<string>127.0.0.1</string>\n		<string>--port</string>\n		<string>49325</string>\n		<string>--local-endpoint-port</string>\n		<string>49326</string>\n		<string>--local-run-dir</string>\n		<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/run</string>\n	</array>\n	<key>RunAtLoad</key>\n	<true/>\n	<key>StandardErrorPath</key>\n	<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/logs/bridge.err.log</string>\n	<key>StandardOutPath</key>\n	<string>/Users/u/.local/share/heimdall/bridges/heimdall-bridge-hub-example-com_work/logs/bridge.out.log</string>\n	<key>ThrottleInterval</key>\n	<integer>5</integer>\n</dict>\n</plist>\n"
@(private="file") GOLD_TASK := "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\n  <RegistrationInfo><Description>Ninjy Bridge https://hub.example.com</Description></RegistrationInfo>\n  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>HOST\\u</UserId></LogonTrigger></Triggers>\n  <Principals><Principal id=\"Author\"><UserId>HOST\\u</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>\n  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure></Settings>\n  <Actions Context=\"Author\"><Exec>\n    <Command>wscript.exe</Command>\n    <Arguments>//B //NoLogo \"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/run.vbs\"</Arguments>\n  </Exec></Actions>\n</Task>\n"
@(private="file") GOLD_RUN_CMD := "@echo off\r\nrem Ninjy bridge for https://hub.example.com (generated by ham-bridge setup)\r\nsetlocal DisableDelayedExpansion\r\nset \"PATH=C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin;/usr/bin:/bin\"\r\nset \"HEIMDALL_HAM_PTY_HOST_BIN=C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-pty-host.exe\"\r\nset \"HEIMDALL_BRIDGE_PTY_HOST=true\"\r\nset \"HEIMDALL_HAM_CTL_BIN=C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-ctl.exe\"\r\nset \"HEIMDALL_BRIDGE_ENDPOINT=tcp:127.0.0.1:49326\"\r\nset \"HEIMDALL_BRIDGE_SERVICE_NAME=heimdall-bridge-hub-example-com_work\"\r\n\"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/bin/ham-bridge.exe\" \"--hub\" \"https://hub.example.com\" \"--config\" \"C:/R/heimdall/bridges/heimdall-bridge-hub-example-com_work/config.toml\" \"--bridge-token-file\" \"C:/R/heimdall/bridges/heimdall-bridge-hub-example-com_work/bridge-token\" \"--data-dir\" \"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work\" \"--bind-host\" \"127.0.0.1\" \"--port\" \"49325\" \"--local-endpoint-port\" \"49326\" \"--local-run-dir\" \"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/run\" 1>>\"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/logs/bridge.out.log\" 2>>\"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/logs/bridge.err.log\" || exit /b 1\r\nexit /b %ERRORLEVEL%\r\n"
@(private="file") GOLD_RUN_VBS := "Option Explicit\r\nDim shell, result\r\nSet shell = CreateObject(\"WScript.Shell\")\r\nresult = shell.Run(\"cmd.exe /d /s /c \"\"\"\"C:/L/heimdall/bridges/heimdall-bridge-hub-example-com_work/run.cmd\"\"\"\"\", 0, True)\r\nWScript.Quit result\r\n"

@(private="file")
conv_input :: proc(converting: bool) -> Render_Input {
	in_ := gold_input()
	in_.converted = true
	in_.converting = converting
	in_.instance_id = "inst-1"
	in_.windows_sid = "S-1-5-21-1"
	return in_
}

@(private="file") LINUX_DATA :: "/home/u/.local/share/heimdall/bridges/" + GOLD_NAME
@(private="file") LINUX_STATE :: "/home/u/.config/heimdall/bridges/" + GOLD_NAME

@(test)
test_converted_systemd :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	linux, _, _ := gold_hosts()
	l := layout_for(linux, GOLD_NAME)
	unit := render_service_file(linux, l, conv_input(false))
	exec := `ExecStart="` + LINUX_DATA + `/launcher/ham-launcher" "--instance-root" "` + LINUX_DATA + `" "--state-root" "` + LINUX_STATE + `"` + "\n"
	testing.expect(t, strings.contains(unit, exec), unit)
	testing.expect(t, strings.contains(unit, "KillMode=control-group\n"), "canonical converted unit")
	testing.expect(t, !strings.contains(unit, "KillMode=process"))
	testing.expect(t, !strings.contains(unit, "ham-bridge"), "no legacy bin/ham-bridge")
	testing.expect(t, !strings.contains(unit, "HEIMDALL_HAM_PTY_HOST_BIN") && !strings.contains(unit, "HEIMDALL_HAM_CTL_BIN"))
	testing.expect(t, strings.contains(unit, `Environment="PATH=/usr/bin:/bin"` + "\n"))
	testing.expect(t, strings.contains(unit, "Restart=on-failure\nRestartSec=5\n"))
	// C6 variant: setup lives in the unit's cgroup (spec §10.1).
	converting := render_service_file(linux, l, conv_input(true))
	testing.expect(t, strings.contains(converting, "KillMode=process\n"))
	testing.expect(t, strings.contains(converting, exec))
	swapped, _ := strings.replace_all(converting, "KillMode=process", "KillMode=control-group", context.temp_allocator)
	testing.expect_value(t, swapped, unit)
}

@(test)
test_converted_launchd :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, mac, _ := gold_hosts()
	l := layout_for(mac, GOLD_NAME)
	plist := render_service_file(mac, l, conv_input(false))
	data :: "/Users/u/.local/share/heimdall/bridges/" + GOLD_NAME
	testing.expect(t, strings.contains(plist, "<key>AbandonProcessGroup</key>\n\t<false/>"))
	testing.expect(t, strings.contains(plist, "<key>ExitTimeOut</key>\n\t<integer>40</integer>"))
	testing.expect(t, strings.contains(plist, "<key>ProgramArguments</key>\n\t<array>\n\t\t<string>" + data + "/launcher/ham-launcher</string>\n\t\t<string>--instance-root</string>\n\t\t<string>" + data + "</string>\n\t\t<string>--state-root</string>\n\t\t<string>/Users/u/.config/heimdall/bridges/" + GOLD_NAME + "</string>\n\t</array>"))
	testing.expect(t, strings.contains(plist, "<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>"))
	testing.expect(t, strings.contains(plist, "<key>ThrottleInterval</key>\n\t<integer>5</integer>"))
	testing.expect(t, strings.contains(plist, "<key>Label</key>\n\t<string>" + GOLD_NAME + "</string>"), "same label")
	testing.expect(t, !strings.contains(plist, "ham-bridge") && !strings.contains(plist, "HEIMDALL_HAM_"))
	// Alphabetical key order is kept: Environment < ExitTimeOut < KeepAlive.
	testing.expect(t, strings.index(plist, "EnvironmentVariables") < strings.index(plist, "ExitTimeOut"))
	testing.expect(t, strings.index(plist, "ExitTimeOut") < strings.index(plist, "KeepAlive"))
	// `converting` only matters for systemd.
	testing.expect_value(t, render_service_file(mac, l, conv_input(true)), plist)
}

@(test)
test_converted_windows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, _, win := gold_hosts()
	l := layout_for(win, GOLD_NAME)
	in_ := conv_input(false)
	xml := render_service_file(win, l, in_)
	data :: "C:/L/heimdall/bridges/" + GOLD_NAME
	testing.expect(t, strings.contains(xml, `//B //NoLogo "` + data + `/run-launcher.vbs"`))
	testing.expect(t, !strings.contains(xml, "/run.vbs"))
	testing.expect(t, strings.contains(xml, `<LogonTrigger><Enabled>true</Enabled><UserId>HOST\u</UserId></LogonTrigger>`))
	testing.expect(t, strings.contains(xml, "<RestartOnFailure><Interval>PT1M</Interval><Count>999</Count>"))
	testing.expect(t, strings.contains(xml, "<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"))

	// Legacy files keep their names so a rollback needs no restore.
	testing.expect_value(t, windows_launcher_cmd_path(l), data + "/run-launcher.cmd")
	testing.expect_value(t, windows_launcher_vbs_path(l), data + "/run-launcher.vbs")
	testing.expect_value(t, windows_launcher_task_xml_path(l), data + "/task-launcher.xml")
	testing.expect_value(t, windows_run_cmd_path(l), data + "/run.cmd")

	vbs := render_windows_launcher_converted(l)
	testing.expect(t, strings.contains(vbs, `""` + data + `/run-launcher.cmd""`))
	testing.expect(t, !strings.contains(vbs, "run.cmd"))

	cmd := render_windows_run_cmd(win, l, in_)
	testing.expect(t, strings.contains(cmd, "\"" + data + "/launcher/ham-launcher.exe\" \"--instance-root\" \"" + data + "\" \"--state-root\" \"C:/R/heimdall/bridges/" + GOLD_NAME + "\" 1>>\"" + data + "/logs/bridge.out.log\" 2>>"))
	testing.expect(t, strings.contains(cmd, "|| exit /b 1\r\nexit /b %ERRORLEVEL%\r\n"))
	testing.expect(t, strings.contains(cmd, "set \"PATH=/usr/bin:/bin\"\r\n"))
	testing.expect(t, !strings.contains(cmd, "HEIMDALL_HAM_") && !strings.contains(cmd, "ham-bridge.exe"))
}

@(test)
test_converted_env :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	linux, _, win := gold_hosts()
	keys :: proc(env: []string) -> string {
		ks := make([dynamic]string, context.temp_allocator)
		for e in env do append(&ks, e[:strings.index_byte(e, '=')])
		return strings.join(ks[:], ",", context.temp_allocator)
	}
	in_ := conv_input(false)
	testing.expect_value(t, keys(service_env(linux, layout_for(linux, GOLD_NAME), in_)), "PATH,HEIMDALL_BRIDGE_PTY_HOST,HEIMDALL_BRIDGE_ENDPOINT,HEIMDALL_BRIDGE_SERVICE_NAME")
	// A captured PATH that already holds the legacy bin/ loses that segment (spec §8.1).
	l := layout_for(linux, GOLD_NAME)
	in_.path_env = "/usr/bin:" + LINUX_DATA + "/bin/:/bin"
	testing.expect_value(t, service_env(linux, l, in_)[0], "PATH=/usr/bin:/bin")
	in_.path_env = LINUX_DATA + "/bin"
	testing.expect_value(t, keys(service_env(linux, l, in_)), "HEIMDALL_BRIDGE_PTY_HOST,HEIMDALL_BRIDGE_ENDPOINT,HEIMDALL_BRIDGE_SERVICE_NAME")
	// Windows uses ';'.
	wl := layout_for(win, GOLD_NAME)
	in_.path_env = "C:/x;C:/L/heimdall/bridges/" + GOLD_NAME + "/bin;C:/y"
	testing.expect_value(t, service_env(win, wl, in_)[0], "PATH=C:/x;C:/y")
	// Legacy is untouched: bin/ first, PTY host and ham-ctl set.
	env := service_env(linux, l, gold_input())
	testing.expect_value(t, env[0], "PATH=" + LINUX_DATA + "/bin:/usr/bin:/bin")
	testing.expect_value(t, len(env), 6)
}

@(test)
test_windows_task_name_and_stop :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := windows_task_name(GOLD_NAME, "S-1-5-21-1", "inst-1")
	testing.expect(t, strings.has_prefix(a, GOLD_NAME + "-"))
	testing.expect_value(t, len(a), len(GOLD_NAME) + 1 + 12)
	for c in a[len(GOLD_NAME) + 1:] do testing.expect(t, (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
	testing.expect_value(t, windows_task_name(GOLD_NAME, "S-1-5-21-1", "inst-1"), a)
	testing.expect(t, windows_task_name(GOLD_NAME, "S-1-5-21-2", "inst-1") != a, "SID changes the name")
	testing.expect(t, windows_task_name(GOLD_NAME, "S-1-5-21-1", "inst-2") != a, "instance changes the name")
	// The 0x00 separators keep ("ab","c") and ("a","bc") apart.
	testing.expect(t, windows_task_name("s", "ab", "c") != windows_task_name("s", "a", "bc"))
	testing.expect_value(t, windows_stop_event_name("inst-1"), `Local\heimdall-launcher-stop-inst-1`)
	_, _, win := gold_hosts()
	l := layout_for(win, GOLD_NAME)
	testing.expect_value(t, launcher_stop_request_path(l), "C:/L/heimdall/bridges/" + GOLD_NAME + "/supervisor/launcher-stop.request")
	testing.expect_value(t, render_launcher_stop_request("inst-1", 1700000000), `{"instance_id":"inst-1","requested_at":1700000000}`)
}
