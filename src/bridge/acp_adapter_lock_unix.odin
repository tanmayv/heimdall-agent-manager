#+build !windows
package main

import "core:c"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"
foreign libc {
    @(link_name = "flock")
    acp_adapter_flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

ACP_Adapter_Lock :: struct { fd: posix.FD }

// flock is bound to the open descriptor, including between threads in one
// process. The kernel releases it after a crash. Keep the inode permanently:
// unlinking a locked path would let a second installer lock a different inode.
acp_adapter_lock_acquire :: proc(path: string) -> (ACP_Adapter_Lock, ACP_Adapter_Lock_State) {
    fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CREAT, .RDWR, .CLOEXEC}, {.IRUSR, .IWUSR})
    if fd < 0 do return {}, .Error
    if acp_adapter_flock(c.int(fd), 2 | 4) != 0 { // LOCK_EX | LOCK_NB
        busy := posix.errno() == .EWOULDBLOCK || posix.errno() == .EAGAIN
        posix.close(fd); return {}, .Busy if busy else .Error
    }
    return {fd}, .Acquired
}

acp_adapter_lock_release :: proc(lock: ACP_Adapter_Lock) { posix.close(lock.fd) }
