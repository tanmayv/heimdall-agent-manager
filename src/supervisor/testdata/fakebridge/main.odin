// fakebridge: the runtime of the supervisor e2e suite (src/supervisor/e2e), installed as
// bin/ham-bridge[.exe] in test release bundles. It stands in for ham-bridge on the
// supervisor<->runtime channel only (spec §12.2), so the e2e needs no hub:
//
//   --version            prints "ham-bridge <bin/test-version.txt>"
//   (anything else)      runs: reads --local-run-dir and --data-dir, listens on loopback TCP,
//                        writes <run>/supervisor-control.json {v,endpoint,token,pid}, answers
//                        supervisor.gate.count / admission.close / admission.open /
//                        sessions.end. pty_sessions = files in <data>/fake-sessions/ (a
//                        test drops a file there for a "live PTY session").
//
// Behaviour: <data>/fake-behaviour/<tree> if it exists (a test can turn an installed
// tree bad later, e.g. to make a rollback fail), else bin/behaviour.txt next to the exe:
//   "good" (default)
//   "crash"    exits 3 s after start, before probation can pass
//   "noready"  never writes the control file (the runtime never becomes ready)
//   "unhealthy" ready, then stops answering 3 s after start (keeps running)
// Every start appends "<pid> <tree> <behaviour> <parent pid> <start_time>" to
// <data>/fake-starts.log (the parent is the supervisor).
//
// Hub: every second the runtime writes <state>/runtime-status.json {pid, connected,
// updated_at} (state = the directory of --config), connected = <data>/fake-hub-up exists
// and <data>/fake-hub-down/<tree> does not (a release that cannot reach the hub).
//
//   --hold <seconds>     a straggler: sleeps, keeping its executable (and so its release
//                        tree) in use (Windows file-in-use tests), then exits 0.
package fakebridge

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import "../../procs"

next_to_exe :: proc(name: string) -> string {
	exe, _ := os.get_executable_path(context.temp_allocator)
	sep := "\\" if ODIN_OS == .Windows else "/"
	return strings.concatenate({os.dir(exe), sep, name}, context.temp_allocator)
}

read_trim :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return strings.trim_space(string(data)) if err == nil else ""
}

join :: proc(a, b: string) -> string {
	sep := "\\" if ODIN_OS == .Windows else "/"
	return strings.concatenate({a, sep, b}, context.allocator)
}

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 && args[0] == "--version" {
		fmt.printfln("ham-bridge %s", read_trim(next_to_exe("test-version.txt")))
		return
	}
	if len(args) > 1 && args[0] == "--hold" {
		secs := 0
		for c in transmute([]byte)args[1] do if c >= '0' && c <= '9' do secs = secs * 10 + int(c - '0')
		time.sleep(time.Duration(secs) * time.Second)
		return
	}
	run_dir, data_dir, config := "", "", ""
	for i := 0; i + 1 < len(args); i += 1 {
		switch args[i] {
		case "--local-run-dir":
			run_dir = args[i + 1]
		case "--data-dir":
			data_dir = args[i + 1]
		case "--config":
			config = args[i + 1]
		}
	}
	if run_dir == "" || data_dir == "" {
		fmt.eprintln("fakebridge: --local-run-dir and --data-dir required")
		os.exit(2)
	}
	exe, _ := os.get_executable_path(context.temp_allocator)
	tree := strings.clone(os.base(os.dir(os.dir(exe))))
	behaviour := read_trim(join(join(data_dir, "fake-behaviour"), tree))
	if behaviour == "" do behaviour = read_trim(next_to_exe("behaviour.txt"))
	behaviour = strings.clone(behaviour) // outlives the per-loop temp reset
	status_path := join(os.dir(config), "runtime-status.json") if config != "" else ""
	hub_flag := join(data_dir, "fake-hub-up")
	hub_blocked := join(join(data_dir, "fake-hub-down"), tree)
	if f, err := os.open(join(data_dir, "fake-starts.log"), {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
		me, _ := procs.self()
		fmt.fprintfln(f, "%d %s %s %d %d", os.get_pid(), tree, behaviour, os.get_ppid(), me.start_time)
		os.close(f)
	}

	sock, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil do os.exit(4)
	ep, _ := net.bound_endpoint(sock)
	net.set_blocking(sock, false)
	token := fmt.aprintf("tok%d%d", os.get_pid(), time.time_to_unix_nano(time.now()))
	control := fmt.tprintf(`{{"v":1,"endpoint":"tcp:127.0.0.1:%d","token":"%s","pid":%d}}`, ep.port, token, os.get_pid())
	_ = os.make_directory_all(run_dir)
	if behaviour != "noready" {
		tmp := join(run_dir, "supervisor-control.json.tmp")
		_ = os.write_entire_file(tmp, transmute([]byte)control)
		_ = os.rename(tmp, join(run_dir, "supervisor-control.json"))
	}

	started := time.tick_now()
	last_status: time.Tick
	admission := "open"
	for {
		free_all(context.temp_allocator)
		if behaviour == "crash" && time.tick_since(started) > 3 * time.Second do os.exit(9)
		if behaviour == "unhealthy" && time.tick_since(started) > 3 * time.Second {
			net.close(sock)
			for {
				time.sleep(time.Second)
			}
		}
		if status_path != "" && (last_status == {} || time.tick_since(last_status) >= time.Second) {
			last_status = time.tick_now()
			st := fmt.tprintf(`{{"pid":%d,"connected":%v,"updated_at":%d}}`, os.get_pid(), os.exists(hub_flag) && !os.exists(hub_blocked), time.time_to_unix(time.now()))
			stmp := strings.concatenate({status_path, ".tmp"}, context.temp_allocator)
			if os.write_entire_file(stmp, transmute([]byte)st) == nil do _ = os.rename(stmp, status_path)
		}
		c, _, aerr := net.accept_tcp(sock)
		if aerr != nil {
			time.sleep(20 * time.Millisecond)
			continue
		}
		net.set_blocking(c, true)
		handle(c, token, data_dir, &admission)
		net.close(c)
	}
}

handle :: proc(c: net.TCP_Socket, token, data_dir: string, admission: ^string) {
	buf := make([dynamic]byte, 0, 1024, context.temp_allocator)
	chunk: [1024]byte
	for {
		n, err := net.recv_tcp(c, chunk[:])
		if err != nil || n <= 0 do return
		append(&buf, ..chunk[:n])
		if strings.contains(string(buf[:]), "\n") do break
		if len(buf) > 65536 do return
	}
	v, perr := json.parse(buf[:], .JSON, true, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	tok, _ := o["token"].(json.String)
	method, _ := o["method"].(json.String)
	reply: string
	if string(tok) != token {
		reply = `{"v":1,"id":"sup","ok":false,"error":"unauthenticated"}`
	} else {
		switch string(method) {
		case "supervisor.gate.count":
			reply = fmt.tprintf(`{{"v":1,"id":"sup","ok":true,"data":{{"counted":true,"admission":"%s","pty_sessions":%d,"launches":0,"helpers":0}}}}`, admission^, sessions(data_dir))
		case "supervisor.admission.close":
			admission^ = "closed"
			reply = `{"v":1,"id":"sup","ok":true,"data":{"admission":"closed","launches":0}}`
		case "supervisor.admission.open":
			admission^ = "open"
			reply = `{"v":1,"id":"sup","ok":true,"data":{"admission":"open"}}`
		case "supervisor.sessions.end":
			reply = `{"v":1,"id":"sup","ok":true,"data":{"signalled":0,"targets":[]}}`
		case:
			reply = `{"v":1,"id":"sup","ok":false,"error":"unknown_method"}`
		}
	}
	line := strings.concatenate({reply, "\n"}, context.temp_allocator)
	_, _ = net.send_tcp(c, transmute([]byte)line)
}

sessions :: proc(data_dir: string) -> int {
	entries, err := os.read_directory_by_path(join(data_dir, "fake-sessions"), -1, context.temp_allocator)
	if err != nil do return 0
	return len(entries)
}
