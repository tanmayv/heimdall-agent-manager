// ham-supervisor: the bridge instance's update engine (docs/specs/bridge-supervisor-engine.md).
//
//   ham-supervisor run --instance-root <data> --state-root <state> --launched-tree <T>
//                      --launch-mode normal|fallback --ready-fd <fd>
//   ham-supervisor repair --instance-root <data> --state-root <state>
//                         --bundle <archive> --manifest <m> --signature <sig> [--op-id <op>]
//   ham-supervisor --version
//
// Phase 1 is dormant (§1): only the launcher of a test root or an opt-in instance runs it;
// it never touches a user's existing bin/. All logic lives in src/supervisor/service.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import httpc "odin_test:lib/httpc"
import "service"
import "engine"
import "fetch"

// TEST builds only: one extra trusted signing key (the e2e suite's fixed test key,
// src/supervisor/testdata/e2e-test-key.pub, second line). The release workflow sets
// neither define; a build that sets this without HEIMDALL_SUPERVISOR_TEST fails to compile.
TEST_PINNED_KEY :: #config(HEIMDALL_TEST_PINNED_KEY, "")
#assert(TEST_PINNED_KEY == "" || service.TEST_BUILD, "HEIMDALL_TEST_PINNED_KEY needs -define:HEIMDALL_SUPERVISOR_TEST=true")

// key_pins: the embedded release keys, plus the test key in a test build (nil = embedded).
key_pins :: proc() -> []fetch.Public_Key {
	when TEST_PINNED_KEY == "" {
		return nil
	} else {
		embedded, err := fetch.pinned_keys()
		if err != nil do return nil
		// Heap copies (key ids are temp strings): the main loop resets the temp allocator.
		out := make([dynamic]fetch.Public_Key)
		for k in embedded do append(&out, fetch.Public_Key{key_id = strings.clone(k.key_id), key = k.key})
		k, kerr := fetch.parse_public_key(strings.concatenate({"untrusted comment: test key\n", TEST_PINNED_KEY, "\n"}, context.temp_allocator))
		if kerr == nil do append(&out, fetch.Public_Key{key_id = strings.clone(k.key_id), key = k.key})
		return out[:]
	}
}

// version_text: `--version`. Test builds append bin/test-version.txt (next to the exe) so
// one test binary can stand in for several release versions in the §14 preflight.
version_text :: proc() -> string {
	v := fmt.tprintf("ham-supervisor %s engine %d journal %d", service.VERSION, engine.ENGINE_VERSION, engine.JOURNAL_SCHEMA)
	when service.TEST_BUILD {
		if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
			if data, rerr := os.read_entire_file(join_path(os.dir(exe), "test-version.txt"), context.temp_allocator); rerr == nil {
				v = fmt.tprintf("%s (test %s)", v, strings.trim_space(string(data)))
			}
		}
	}
	return v
}

USAGE :: `usage:
  ham-supervisor run --instance-root <data> --state-root <state> --launched-tree <T> --launch-mode normal|fallback [--ready-fd <fd>]
  ham-supervisor repair --instance-root <data> --state-root <state> --bundle <archive> --manifest <m> --signature <sig> [--op-id <op>]
  ham-supervisor --version`

usage :: proc() -> ! {
	fmt.eprintln(USAGE)
	os.exit(2)
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 do usage()
	if args[0] == "--version" {
		fmt.println(version_text())
		os.exit(0)
	}
	cmd := args[0]
	flags := make(map[string]string)
	for i := 1; i < len(args); i += 1 {
		if i + 1 >= len(args) do usage()
		switch args[i] {
		case "--instance-root", "--state-root", "--launched-tree", "--launch-mode", "--ready-fd", "--bundle", "--manifest", "--signature", "--op-id":
			flags[args[i]] = args[i + 1]
			i += 1
		case:
			usage()
		}
	}
	if flags["--instance-root"] == "" || flags["--state-root"] == "" do usage()
	if ok, msg := httpc.init(); !ok && cmd == "run" {
		// The resolver and downloads need libcurl; without it the supervisor still runs the
		// installed release (every check fails resolve_incomplete / download_failed).
		fmt.eprintfln("ham-supervisor: http client unavailable: %s", msg)
	}
	switch cmd {
	case "run":
		mode: engine.Mode
		switch flags["--launch-mode"] {
		case "normal":
			mode = .Normal
		case "fallback":
			mode = .Fallback
		case:
			usage()
		}
		if flags["--launched-tree"] == "" do usage()
		// Heap copy: the main loop resets the temp allocator every second.
		nctx := Net_Ctx{scratch_dir = strings.clone(join_path(flags["--instance-root"], "supervisor", "downloads"))}
		os.exit(service.run_supervisor({
			instance_root = flags["--instance-root"],
			state_root = flags["--state-root"],
			launched = flags["--launched-tree"],
			mode = mode,
			ready_fd = flags["--ready-fd"],
			net = real_net(&nctx),
			key_pins = key_pins(),
		}))
	case "repair":
		if flags["--bundle"] == "" || flags["--manifest"] == "" || flags["--signature"] == "" do usage()
		os.exit(service.repair({
			instance_root = flags["--instance-root"],
			state_root = flags["--state-root"],
			bundle = flags["--bundle"],
			manifest = flags["--manifest"],
			signature = flags["--signature"],
			op_id = flags["--op-id"],
			actor = "installer",
			key_pins = key_pins(),
			log = service.stderr_log,
		}))
	case:
		usage()
	}
}

join_path :: proc(parts: ..string) -> string {
	return engine.join(..parts)
}
