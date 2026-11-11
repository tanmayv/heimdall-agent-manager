#+build !windows
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"

// The socket bridge_pty_host_ensure_daemon returns is the process-global cache.
// A reviewer wake that freed it left every later ensure_daemon pinging a
// reused (garbage) path: the Bridge then killed its healthy daemon, taking
// every agent PTY with it, and could never start a replacement (Mundus .9,
// "cannot prepare socket directory hlat_…"). Two wakes in a row must both
// reach the daemon, and the cached path must be intact afterwards.
@(test)
test_owner_review_nudge_keeps_the_cached_daemon_socket :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)

	path := fmt.aprintf("/tmp/ham-review-nudge-%d.sock", os.get_pid())
	defer delete(path)
	_ = posix.unlink(cstring(raw_data(path)))
	defer _ = posix.unlink(cstring(raw_data(path)))
	listener := posix.socket(.UNIX, .STREAM)
	if !testing.expect(t, listener >= 0) do return
	defer posix.close(listener)
	addr: posix.sockaddr_un
	when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .NetBSD || ODIN_OS == .OpenBSD {
		addr.sun_len = c.uchar(size_of(addr))
	}
	addr.sun_family = .UNIX
	for ch, i in path do addr.sun_path[i] = c.char(ch)
	if !testing.expect(t, posix.bind(listener, (^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr))) == .OK) do return
	if !testing.expect(t, posix.listen(listener, 8) == .OK) do return
	Server :: struct {
		listener: posix.FD,
		pings, inputs: int,
		stop: bool,
	}
	server := Server{listener = listener}
	worker := bridge_thread_start_with_data(&server, proc(data: rawptr) {
		context.allocator = runtime.heap_allocator()
		s := (^Server)(data)
		for !sync.atomic_load(&s.stop) {
			pfd := posix.pollfd{fd = s.listener, events = {.IN}}
			if posix.poll(&pfd, 1, 50) <= 0 do continue
			fd := posix.accept(s.listener, nil, nil)
			if fd < 0 do continue
			request, ok := pty_host_read_frame(fd)
			if ok && len(request) > 0 {
				switch request[0] {
				case PTY_HOST_T_PING:
					s.pings += 1
					reply := pty_host_frame([]byte{PTY_HOST_T_PONG})
					_ = pty_host_send_all(fd, reply)
					delete(reply)
				case PTY_HOST_T_INPUT:
					s.inputs += 1
				}
			}
			delete(request)
			posix.close(fd)
		}
	})
	defer thread.destroy(worker)
	swap := pty_host_test_install_socket(path)
	defer pty_host_test_restore_socket(swap)

	for i in 0..<2 {
		testing.expectf(t, bridge_owner_review_nudge("inst_review_nudge", "New review lease"), "wake %d reaches the daemon", i)
		testing.expectf(t, strings.clone(pty_host_daemon().socket, context.temp_allocator) == path, "the cached daemon socket is intact after wake %d", i)
	}
	sync.atomic_store(&server.stop, true)
	thread.join(worker)
	testing.expect(t, server.pings >= 2 && server.inputs == 2, fmt.tprintf("both wakes pinged and typed: pings=%d inputs=%d", server.pings, server.inputs))
}
