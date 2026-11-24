#+build windows
package e2e

import win "core:sys/windows"

HOLDS_BLOCK :: true // a handle without FILE_SHARE_DELETE blocks rename/replace (W3)

Hold :: struct {
	h: win.HANDLE,
}

// hold_open opens `path` (a file, or a directory when dir) sharing read and write but not
// delete, the way an antivirus scanner holds a freshly written file: renames and
// ReplaceFileW on it (or, for a directory, on its parent tree) fail with sharing
// violations until hold_close.
hold_open :: proc(path: string, dir := false) -> (Hold, bool) {
	flags: win.DWORD = win.FILE_ATTRIBUTE_NORMAL
	if dir do flags = win.FILE_FLAG_BACKUP_SEMANTICS
	h := win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, flags, nil)
	if h == win.INVALID_HANDLE_VALUE do return {}, false
	return {h = h}, true
}

hold_close :: proc(h: ^Hold) {
	if h.h != nil do win.CloseHandle(h.h)
	h.h = nil
}
