package main

import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

main :: proc() {
	if has_flag(os.args, "--version") {
		fmt.println("ham-daemon", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
		return
	}
	if has_flag(os.args, "--help") || has_flag(os.args, "-h") {
		print_usage()
		return
	}

	config_path := cfg_lib.config_path_from_args(os.args)
	loaded, ok := cfg_lib.load(config_path)
	if !ok {
		fmt.println("failed to load config", config_path)
		return
	}

	run_server(loaded.config, loaded.path)
}

has_flag :: proc(args: []string, flag: string) -> bool {
	for arg in args {
		if arg == flag do return true
	}
	return false
}

print_usage :: proc() {
	fmt.println("ham-daemon", contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.println("usage: ham-daemon [--config <path>] [--version] [--help]")
}
