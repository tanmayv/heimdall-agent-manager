package main

// A stand-in for the NEW bundle's ham-bridge, used by tests/e2e/legacy_updater_compat_e2e.mjs.
// The real, released v0.5.77 (and the newest legacy) `ham-bridge update --auto-worker` runs
// this binary exactly as it will run the first supervisor release: `--version` as a
// preflight, then `setup --hub H [--profile P] --headless [--reinstall] [--json-progress]`
// with the worker's own stdio, waiting for the exit code with no timeout. The stub records
// what the old worker did to it, so the compatibility contract (docs/specs/
// bridge-supervisor-conversion.md §1, §11) is asserted against the real old binary.
//
//   STUB_VERSION   version printed by --version                (default 99.0.0)
//   STUB_RECORD    file the setup call writes its record to    (required for setup)
//   STUB_HOLD_MS   how long setup runs before it exits         (default 0)
//   STUB_EXIT      setup's exit code                           (default 0)

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:terminal"
import "core:time"

env_or :: proc(name, fallback: string) -> string {
	if v, ok := os.lookup_env(name, context.temp_allocator); ok && v != "" do return v
	return fallback
}

json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"': strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case: if c < 0x20 do fmt.sbprintf(b, "\\u%04x", c); else do strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

main :: proc() {
	args := os.args[1:]
	if len(args) >= 1 && args[0] == "--version" {
		fmt.printfln("ham-bridge %s (legacy update stub)", env_or("STUB_VERSION", "99.0.0"))
		return
	}
	if len(args) < 1 || args[0] != "setup" {
		fmt.eprintln("legacy_update_stub: only --version and setup are supported")
		os.exit(64)
	}
	record := env_or("STUB_RECORD", "")
	if record == "" {
		fmt.eprintln("legacy_update_stub: STUB_RECORD is required for setup")
		os.exit(64)
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `{"argv":[`)
	for a, i in args {
		if i > 0 do strings.write_byte(&b, ',')
		json_string(&b, a)
	}
	fmt.sbprintf(&b, `],"stdin_tty":%v,"stdout_tty":%v,"stderr_tty":%v,"started_ms":%d}`,
		terminal.is_terminal(os.stdin), terminal.is_terminal(os.stdout), terminal.is_terminal(os.stderr),
		time.to_unix_nanoseconds(time.now()) / 1_000_000)
	// The record is the proof the setup ran; written before the hold so the test can see it
	// while the old worker is still waiting.
	if err := os.write_entire_file_from_string(record, strings.to_string(b)); err != nil {
		fmt.eprintfln("legacy_update_stub: cannot write %s: %v", record, err)
		os.exit(65)
	}
	hold, _ := strconv.parse_int(env_or("STUB_HOLD_MS", "0"))
	if hold > 0 do time.sleep(time.Duration(hold) * time.Millisecond)
	code, _ := strconv.parse_int(env_or("STUB_EXIT", "0"))
	os.exit(code)
}
