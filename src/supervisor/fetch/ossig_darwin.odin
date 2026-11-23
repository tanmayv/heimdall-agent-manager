#+build darwin
package fetch

import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"

CODESIGN :: "/usr/bin/codesign"
CODESIGN_TIMEOUT_MS :: 30_000

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
	removexattr :: proc(path: cstring, name: cstring, options: c.int) -> c.int ---
	getxattr :: proc(path: cstring, name: cstring, value: rawptr, size: c.size_t, position: u32, options: c.int) -> c.ssize_t ---
	setxattr :: proc(path: cstring, name: cstring, value: rawptr, size: c.size_t, position: u32, options: c.int) -> c.int ---
}

XATTR_NOFOLLOW :: 0x0001
ENOATTR :: 93 // <sys/errno.h>
QUARANTINE_XATTR :: "com.apple.quarantine"

// is_macho: thin (32/64-bit, either byte order) or fat (universal) Mach-O.
@(private)
is_macho :: proc(path: string) -> bool {
	f, err := os.open(path)
	if err != nil do return false
	defer os.close(f)
	b: [8]byte
	n, _ := os.read(f, b[:])
	if n < 8 do return false
	be := u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
	switch be {
	case 0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe:
		return true
	case 0xcafebabe, 0xbebafeca:
		// Java class files share 0xcafebabe; a fat header has a small arch count.
		nfat := u32(b[4]) << 24 | u32(b[5]) << 16 | u32(b[6]) << 8 | u32(b[7])
		if be == 0xbebafeca do nfat = u32(b[7]) << 24 | u32(b[6]) << 16 | u32(b[5]) << 8 | u32(b[4])
		return nfat > 0 && nfat < 32
	}
	return false
}

@(private)
os_signature_state :: proc(path, rel: string) -> (state: Signature_State, identity: string, detail: string) {
	if !is_macho(path) do return .Not_Applicable, "", ""
	code, _, stderr, ran := run_process({CODESIGN, "--verify", "--strict", "--", path}, CODESIGN_TIMEOUT_MS)
	if !ran do return .Invalid, "", "codesign could not run"
	if code != 0 {
		if strings.contains(stderr, "not signed at all") do return .Unsigned, "", strings.trim_space(stderr)
		return .Invalid, "", strings.trim_space(stderr)
	}
	code2, _, info, ran2 := run_process({CODESIGN, "-d", "--verbose=2", "--", path}, CODESIGN_TIMEOUT_MS)
	if !ran2 || code2 != 0 do return .Invalid, "", strings.trim_space(info)
	team := ""
	for line in strings.split_lines(info, context.temp_allocator) {
		if strings.has_prefix(line, "TeamIdentifier=") do team = strings.trim_space(line[len("TeamIdentifier="):])
	}
	if team == "not set" do team = "" // ad-hoc or linker-signed
	return .Valid, team, "ad-hoc or no Team ID" if team == "" else ""
}

// clear_quarantine removes com.apple.quarantine from every extracted file and
// directory. Files written by this process do not get the attribute unless
// the process is quarantine-enabled (LSFileQuarantineEnabled), which a
// command-line supervisor is not; this is the safety net the spec asks for,
// run only after the signature check passed.
@(private)
clear_quarantine :: proc(staging: string, files: []Extracted_File) -> Error {
	for f in files {
		path := strings.clone_to_cstring(native_join(staging, f.path), context.temp_allocator)
		if removexattr(path, QUARANTINE_XATTR, XATTR_NOFOLLOW) != 0 {
			errno := posix.errno()
			if i32(errno) != ENOATTR do return fail(.Fs_Error, "%s: removexattr: %v", f.path, errno)
		}
	}
	return nil
}

// has_quarantine reports whether path carries com.apple.quarantine (tests).
has_quarantine :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	return getxattr(cpath, QUARANTINE_XATTR, nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

// set_quarantine adds a quarantine attribute (tests).
set_quarantine :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	value := "0081;00000000;Safari;"
	return setxattr(cpath, QUARANTINE_XATTR, raw_data(value), c.size_t(len(value)), 0, XATTR_NOFOLLOW) == 0
}
