package main

import "core:net"
import re "odin_test:lib/router_envelope"

handle_router_envelope_ingress :: proc(client: net.TCP_Socket, body: string) {
	envelope, ok := re.router_envelope_from_json(body)
	if !ok {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid encrypted envelope"}`)
		return
	}
	command, command_ok := router_adapter_command_from_envelope(envelope, hub_adapter_config.user_token)
	if !command_ok {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"unsupported encrypted payload"}`)
		return
	}
	result := message_service_execute(command)
	if !result.ok {
		write_response(client, result.status_code, result.status_text, result.message)
		return
	}
	write_response(client, 200, "OK", `{"ok":true,"message":"encrypted envelope applied"}`)
}
