#+build linux, darwin
package e2e

import "core:os"

HOLDS_BLOCK :: false // POSIX renames are not blocked by open handles (W1-W9 harmless)

Hold :: struct {
	f: ^os.File,
}

hold_open :: proc(path: string, dir := false) -> (Hold, bool) {
	f, err := os.open(path)
	if err != nil do return {}, false
	return {f = f}, true
}

hold_close :: proc(h: ^Hold) {
	if h.f != nil do os.close(h.f)
	h.f = nil
}
