// Shared real JetStream harness. Requires nats-server on PATH (nix develop).
package natstest

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Server :: struct {
	process:        os.Process,
	directory, url: string,
}

// Caller owns the returned Server. Always destroy it, including on failure.
// nats-server chooses the port itself (-p -1), avoiding probe/rebind races.
start :: proc(extra_args: []string = nil) -> (server: Server, ok: bool) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if terr != nil do return
	server.directory = fmt.aprintf("%s/heimdall-nats-%d-%d", tmp, os.get_pid(), time.tick_now()._nsec)
	if os.make_directory(server.directory) != nil do return
	store := fmt.tprintf("%s/store", server.directory)
	command := make([dynamic]string)
	defer delete(command)
	append(
		&command,
		..([]string {
				"nats-server",
				"-js",
				"-a",
				"127.0.0.1",
				"-p",
				"-1",
				"-sd",
				store,
				"--ports_file_dir",
				server.directory,
			}),
	)
	append(&command, ..extra_args)
	server.process, terr = os.process_start(os.Process_Desc{command = command[:]})
	if terr != nil do return
	ports_path := fmt.tprintf("%s/nats-server_%d.ports", server.directory, server.process.pid)
	for _ in 0 ..< 250 {
		data, read_ok := os.read_entire_file(ports_path, context.allocator)
		if read_ok == nil {
			ports: struct {
				nats: []string,
			}
			err := json.unmarshal(data, &ports)
			if err == nil && len(ports.nats) > 0 {
				server.url = strings.clone(ports.nats[0])
				ok = true
			}
			for url in ports.nats do delete(url)
			delete(ports.nats)
			delete(data)
			if ok do return
		}
		time.sleep(20 * time.Millisecond)
	}
	return
}

// Stops and reaps only this child. Keeps URL/store for outage assertions.
stop :: proc(server: ^Server) {
	if server.process.pid != 0 {
		_ = os.process_kill(server.process)
		_, _ = os.process_wait(server.process)
		server.process = {}
	}
}

// Stops child and removes its private store. Frees strings with caller allocator.
destroy :: proc(server: ^Server) {
	stop(server)
	if server.directory != "" do _ = os.remove_all(server.directory)
	delete(server.directory)
	delete(server.url)
	server^ = {}
}

// Restarts the same private store/listen port after stop for recovery tests.
restart :: proc(server: ^Server) -> bool {
	if server.process.pid != 0 || server.url == "" do return false
	colon := strings.last_index_byte(server.url, ':')
	if colon < 0 do return false
	store := fmt.tprintf("%s/store", server.directory)
	command := []string{"nats-server", "-js", "-a", "127.0.0.1", "-p", server.url[colon + 1:], "-sd", store, "--ports_file_dir", server.directory}
	process, err := os.process_start({command = command})
	if err != nil do return false
	server.process = process
	path := fmt.tprintf("%s/nats-server_%d.ports", server.directory, process.pid)
	for _ in 0 ..< 250 {
		if os.exists(path) do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}
