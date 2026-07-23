package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import app "odin_test:hub/app"

main :: proc() {
	config := app.default_config()
	parse_args(&config)
	ok, message := app.run(config)
	if !ok {
		fmt.eprintln(message)
		return
	}
	fmt.println(message)
}

parse_args :: proc(config: ^app.Hub_Config) {
	for i := 1; i < len(os.args); i += 1 {
		arg := os.args[i]
		if arg == "--listen" && i + 1 < len(os.args) {
			host, port, ok := split_host_port(os.args[i + 1])
			if ok {
				config.bind_host = host
				config.port = port
			}
			i += 1
		} else if arg == "--port" && i + 1 < len(os.args) {
			if parsed, ok := strconv.parse_int(os.args[i + 1]); ok do config.port = int(parsed)
			i += 1
		} else if arg == "--db" && i + 1 < len(os.args) {
			config.database_path = strings.clone(os.args[i + 1]); i += 1
		} else if arg == "--trusted-proxy-cidr" && i + 1 < len(os.args) {
			cidrs := make([]string, 1)
			cidrs[0] = strings.clone(os.args[i + 1])
			config.trusted_proxy_cidrs = cidrs
			i += 1
		} else if arg == "--logout-url" && i + 1 < len(os.args) {
			config.logout_url = strings.clone(os.args[i + 1]); i += 1
		}
	}
}

split_host_port :: proc(value: string) -> (string, int, bool) {
	colon := strings.last_index_byte(value, ':')
	if colon < 0 do return "", 0, false
	port_i, ok := strconv.parse_int(value[colon + 1:])
	if !ok do return "", 0, false
	return strings.clone(value[:colon]), int(port_i), true
}
