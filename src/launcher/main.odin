// ham-launcher: the tiny boot program the OS service runs (docs/specs/bridge-supervisor-engine.md §7).
//
//   ham-launcher --instance-root <data> --state-root <state>
//
// It reads instance.json, current, previous and known-good.json, starts the
// supervisor of `current`, and falls back to `previous` when that supervisor does not
// report healthy. All logic lives in src/launcher/core.
package main

import "core:fmt"
import "core:os"
import launcher "odin_test:launcher/core"

USAGE :: "usage: ham-launcher --instance-root <data> --state-root <state>"

main :: proc() {
	cfg := launcher.Config{timeouts = launcher.DEFAULT_TIMEOUTS}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--instance-root", "--state-root":
			if i + 1 >= len(args) {
				fmt.eprintln(USAGE)
				os.exit(2)
			}
			if args[i] == "--instance-root" do cfg.instance_root = args[i + 1]
			else do cfg.state_root = args[i + 1]
			i += 1
		case "--version":
			fmt.printfln("ham-launcher %s abi %d", launcher.VERSION, launcher.ABI)
			os.exit(0)
		case:
			fmt.eprintln(USAGE)
			os.exit(2)
		}
	}
	if cfg.instance_root == "" || cfg.state_root == "" {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	os.exit(launcher.run(cfg))
}
