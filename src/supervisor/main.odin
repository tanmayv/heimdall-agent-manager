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
import httpc "odin_test:lib/httpc"
import "service"
import "engine"

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
		fmt.printfln("ham-supervisor %s engine %d journal %d", service.VERSION, engine.ENGINE_VERSION, engine.JOURNAL_SCHEMA)
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
		nctx := Net_Ctx{scratch_dir = join_path(flags["--instance-root"], "supervisor", "downloads")}
		os.exit(service.run_supervisor({
			instance_root = flags["--instance-root"],
			state_root = flags["--state-root"],
			launched = flags["--launched-tree"],
			mode = mode,
			ready_fd = flags["--ready-fd"],
			net = real_net(&nctx),
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
			log = service.stderr_log,
		}))
	case:
		usage()
	}
}

join_path :: proc(parts: ..string) -> string {
	return engine.join(..parts)
}
