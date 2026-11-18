#+build windows
package main

import win "core:sys/windows"

ACP_Adapter_Lock :: struct { handle: win.HANDLE }

acp_adapter_lock_acquire :: proc(path: string) -> (ACP_Adapter_Lock, ACP_Adapter_Lock_State) {
    handle := win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), win.GENERIC_READ | win.GENERIC_WRITE,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
    if handle == win.INVALID_HANDLE_VALUE do return {}, .Error
    overlapped: win.OVERLAPPED
    if !win.LockFileEx(handle, win.LOCKFILE_EXCLUSIVE_LOCK | win.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &overlapped) {
        busy := win.GetLastError() == 33 // ERROR_LOCK_VIOLATION
        win.CloseHandle(handle); return {}, .Busy if busy else .Error
    }
    return {handle}, .Acquired
}

acp_adapter_lock_release :: proc(lock: ACP_Adapter_Lock) { win.CloseHandle(lock.handle) }
