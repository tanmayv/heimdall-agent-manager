package resolver

// Strict SemVer 2.0.0 for release tags (docs/specs/bridge-supervisor-engine.md
// §13.1): a tag is "v" + SemVer; anything else is not a release candidate.
// Numeric fields are compared as digit strings so no identifier can overflow.

import "core:strings"

Semver :: struct {
	major, minor, patch: string, // digit strings, no leading zeros (except "0")
	pre:                 string, // prerelease identifiers without the leading '-', "" when none
}

// semver_parse_tag accepts exactly "v<MAJOR>.<MINOR>.<PATCH>[-<pre>][+<build>]".
semver_parse_tag :: proc(tag: string) -> (v: Semver, ok: bool) {
	if !strings.has_prefix(tag, "v") do return {}, false
	return semver_parse(tag[1:])
}

semver_parse :: proc(s: string) -> (v: Semver, ok: bool) {
	rest := s
	if i := strings.index_byte(rest, '+'); i >= 0 {
		if !semver_idents_valid(rest[i + 1:], false) do return {}, false
		rest = rest[:i]
	}
	if i := strings.index_byte(rest, '-'); i >= 0 {
		v.pre = rest[i + 1:]
		if !semver_idents_valid(v.pre, true) do return {}, false
		rest = rest[:i]
	}
	// split_iterator drops a trailing empty field, so count the dots first.
	if strings.count(rest, ".") != 2 do return {}, false
	parts: [3]string
	n := 0
	for part in strings.split_iterator(&rest, ".") {
		if n == 3 do return {}, false
		parts[n] = part
		n += 1
	}
	if n != 3 do return {}, false
	for p in parts {
		if !semver_numeric(p) do return {}, false
	}
	v.major, v.minor, v.patch = parts[0], parts[1], parts[2]
	return v, true
}

// semver_compare returns -1, 0 or 1 by SemVer §11 precedence (build metadata ignored).
semver_compare :: proc(a, b: Semver) -> int {
	if c := digits_compare(a.major, b.major); c != 0 do return c
	if c := digits_compare(a.minor, b.minor); c != 0 do return c
	if c := digits_compare(a.patch, b.patch); c != 0 do return c
	if a.pre == b.pre do return 0
	if a.pre == "" do return 1
	if b.pre == "" do return -1
	ar, br := a.pre, b.pre
	for {
		ai, a_more := strings.split_iterator(&ar, ".")
		bi, b_more := strings.split_iterator(&br, ".")
		if !a_more && !b_more do return 0
		if !a_more do return -1
		if !b_more do return 1
		an, bn := all_digits(ai), all_digits(bi)
		switch {
		case an && bn:
			if c := digits_compare(ai, bi); c != 0 do return c
		case an:
			return -1
		case bn:
			return 1
		case ai != bi:
			return -1 if ai < bi else 1
		}
	}
}

// semver_compare_strings compares two plain versions (no "v"); an invalid
// version sorts below every valid one so it can never win a comparison.
semver_compare_strings :: proc(a, b: string) -> int {
	av, a_ok := semver_parse(a)
	bv, b_ok := semver_parse(b)
	if !a_ok || !b_ok {
		if a_ok == b_ok do return 0
		return 1 if a_ok else -1
	}
	return semver_compare(av, bv)
}

@(private)
semver_numeric :: proc(s: string) -> bool {
	if !all_digits(s) do return false
	return len(s) == 1 || s[0] != '0'
}

@(private)
semver_idents_valid :: proc(s: string, prerelease: bool) -> bool {
	if s == "" || strings.has_suffix(s, ".") do return false
	rest := s
	for ident in strings.split_iterator(&rest, ".") {
		if ident == "" do return false
		for c in transmute([]byte)ident {
			switch c {
			case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '-':
			case: return false
			}
		}
		// Numeric prerelease identifiers must not have leading zeros (§9).
		if prerelease && all_digits(ident) && !semver_numeric(ident) do return false
	}
	return true
}

@(private)
all_digits :: proc(s: string) -> bool {
	if s == "" do return false
	for c in transmute([]byte)s {
		if c < '0' || c > '9' do return false
	}
	return true
}

@(private)
digits_compare :: proc(a, b: string) -> int {
	if len(a) != len(b) do return -1 if len(a) < len(b) else 1
	if a == b do return 0
	return -1 if a < b else 1
}
