package contracts

import "core:strings"

// GET /bridges[].update_choices. Versions are exact release tags; only newer
// prereleases and the latest stable release are offered. Missing bundles stay
// visible but disabled. POST /bridges/{id}/update requires allow_downgrade=true
// for an older target, independently of the force/drain policy.
Bridge_Update_Choice :: struct {
	version: string,
	prerelease: bool,
	downgrade: bool,
	artifact_available: bool,
}

// SemVer precedence, ignoring a tag's v prefix and build metadata. Release
// numbers are compared as digit strings so large identifiers cannot overflow.
release_version_compare :: proc(a, b: string) -> int {
	ac, ap := release_version_parts(release_version_clean(a))
	bc, bp := release_version_parts(release_version_clean(b))
	aa := strings.split(ac, ".", context.temp_allocator)
	bb := strings.split(bc, ".", context.temp_allocator)
	for i in 0..<3 {
		av, bv := "0", "0"
		if i < len(aa) do av = aa[i]
		if i < len(bb) do bv = bb[i]
		if c := release_number_compare(av, bv); c != 0 do return c
	}
	if ap == bp do return 0
	if ap == "" do return 1
	if bp == "" do return -1
	aa, bb = strings.split(ap, ".", context.temp_allocator), strings.split(bp, ".", context.temp_allocator)
	for i in 0..<min(len(aa), len(bb)) {
		an, bn := release_digits(aa[i]), release_digits(bb[i])
		if an && bn {
			if c := release_number_compare(aa[i], bb[i]); c != 0 do return c
		} else if an != bn {
			return -1 if an else 1
		} else if aa[i] != bb[i] {
			return -1 if aa[i] < bb[i] else 1
		}
	}
	if len(aa) == len(bb) do return 0
	return -1 if len(aa) < len(bb) else 1
}

release_version_clean :: proc(value: string) -> string {
	s := strings.trim_space(value)
	if strings.has_prefix(s, "v") || strings.has_prefix(s, "V") do s = s[1:]
	if i := strings.index_byte(s, '+'); i >= 0 do s = s[:i]
	return s
}

release_version_parts :: proc(s: string) -> (core, pre: string) {
	if i := strings.index_byte(s, '-'); i >= 0 do return s[:i], s[i+1:]
	return s, ""
}

release_digits :: proc(s: string) -> bool {
	if s == "" do return false
	for c in s { if c < '0' || c > '9' do return false }
	return true
}

release_number_compare :: proc(left, right: string) -> int {
	a, b := strings.trim_left(left, "0"), strings.trim_left(right, "0")
	if len(a) != len(b) do return -1 if len(a) < len(b) else 1
	if a == b do return 0
	return -1 if a < b else 1
}

release_version_valid :: proc(s: string) -> bool {
	core, pre := release_version_parts(release_version_clean(s))
	parts := strings.split(core, ".", context.temp_allocator)
	if len(parts) != 3 do return false
	for part in parts { if !release_digits(part) do return false }
	if strings.contains(s, "-") && pre == "" do return false
	return true
}
