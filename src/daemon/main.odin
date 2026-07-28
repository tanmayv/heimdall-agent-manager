package main

import "core:fmt"
import "core:os"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"

main :: proc() {
	fmt.println("ham-daemon is deprecated and has been replaced by ham-hub and ham-bridge.")
	fmt.println("Start ham-hub for the hub/control-plane process and ham-bridge for the local bridge/runtime process.")
	return
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
