package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

main :: proc() {
	if has_flag(os.args, "--version") {
		fmt.println(server_binary_name(), contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
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

server_binary_name :: proc() -> string {
	name := "ham-hub"
	if len(os.args) > 0 && os.args[0] != "" {
		name = os.args[0]
		if slash := strings.last_index_byte(name, '/'); slash >= 0 && slash + 1 < len(name) do name = name[slash + 1:]
		if slash := strings.last_index_byte(name, '\\'); slash >= 0 && slash + 1 < len(name) do name = name[slash + 1:]
	}
	if name == "" do return "ham-hub"
	return name
}

print_usage :: proc() {
	name := server_binary_name()
	fmt.println(name, contracts.APP_VERSION, "protocol", contracts.PROTOCOL_VERSION)
	fmt.printfln("usage: %s [--config <path>] [--version] [--help]", name)
}
