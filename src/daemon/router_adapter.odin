package main

import "core:fmt"
import contracts "odin_test:contracts"
import cfg_lib "odin_test:lib/config"
import re "odin_test:lib/router_envelope"

Hub_Adapter_Config :: struct {
	enabled: bool,
	user_id: string,
	namespace: string,
	local_daemon_id: string,
	hub_auth_token: string,
	user_token: string,
}

hub_adapter_config: Hub_Adapter_Config

router_adapter_init :: proc(cfg: cfg_lib.Daemon_Config) {
	hub_adapter_config = Hub_Adapter_Config {
		enabled = cfg.hub_enabled,
		user_id = cfg.user_id,
		namespace = cfg.namespace,
		local_daemon_id = cfg.daemon_id,
		hub_auth_token = cfg.hub_auth_token,
		user_token = cfg.user_token,
	}
	central_hub_presence(hub_adapter_config.user_id, hub_adapter_config.namespace, hub_adapter_config.local_daemon_id, "", "daemon-online")
}

router_adapter_announce_local_agent :: proc(agent_instance_id, agent_class: string) {
	central_hub_presence(hub_adapter_config.user_id, hub_adapter_config.namespace, hub_adapter_config.local_daemon_id, agent_instance_id, "agent-registered")
	if hub_adapter_config.enabled {
		fmt.println("hub_adapter announce_local_agent", agent_instance_id, "class", agent_class, "daemon", hub_adapter_config.local_daemon_id)
	}
}

hub_adapter_append_event :: proc(event: Message_Event) -> bool {
	if !hub_adapter_config.enabled do return false
	payload_type, payload_json := router_payload_from_message_event(event)
	if payload_type == "" do return false
	crypto := re.encrypt_payload_for_router(payload_json, hub_adapter_config.user_token)
	if !crypto.ok do return false
	record_id := fmt.tprintf("hub_%d_%s", router_now_unix_ms(), string(event.message_id))
	message_id := string(event.message_id)
	if message_id == "" do message_id = record_id
	kind := Hub_Record_Kind.Message_Send
	if payload_type == re.PAYLOAD_MESSAGE_READ do kind = .Message_Read
	_, ok := central_hub_append(Hub_Record {
		record_id = record_id,
		message_id = message_id,
		kind = kind,
		user_id = hub_adapter_config.user_id,
		namespace = hub_adapter_config.namespace,
		source_daemon_id = hub_adapter_config.local_daemon_id,
		target_agent_instance_id = string(event.target_agent_instance_id),
		payload_type = payload_type,
		payload_version = re.PAYLOAD_VERSION,
		encrypted_payload_json = crypto.encrypted_payload_json,
	})
	return ok
}

hub_adapter_authorized :: proc(user_id, namespace, hub_auth_token: string) -> bool {
	return user_id == hub_adapter_config.user_id && namespace == hub_adapter_config.namespace && hub_auth_token == hub_adapter_config.hub_auth_token
}

hub_adapter_command_from_record :: proc(record: Hub_Record) -> (Command, bool) {
	crypto := re.decrypt_payload_from_router(record.encrypted_payload_json, hub_adapter_config.user_token)
	if !crypto.ok do return Command{}, false
	if record.payload_type == re.PAYLOAD_MESSAGE_SEND {
		payload, ok := re.parse_message_send_payload_json(crypto.payload_json)
		if !ok do return Command{}, false
		return Command {
			source = .Remote_Router_Envelope,
			kind = .Send_Message,
			send_message = Send_Message_Command {
				from_agent_instance_id = contracts.Agent_Instance_ID(payload.from_agent_instance_id),
				target_agent_instance_id = contracts.Agent_Instance_ID(payload.target_agent_instance_id),
				payload = payload.body,
			},
		}, true
	}
	if record.payload_type == re.PAYLOAD_MESSAGE_READ {
		payload, ok := re.parse_message_read_payload_json(crypto.payload_json)
		if !ok do return Command{}, false
		return Command {
			source = .Remote_Router_Envelope,
			kind = .Mark_Read,
			mark_read = Mark_Read_Command {
				agent_instance_id = contracts.Agent_Instance_ID(payload.read_by_agent_instance_id),
				conversation_id = contracts.Conversation_ID(payload.conversation_id),
				message_id = contracts.Message_ID(payload.message_id),
				read_unix_ms = payload.read_unix_ms,
			},
		}, true
	}
	return Command{}, false
}

hub_adapter_apply_polled_record :: proc(record: Hub_Record) -> bool {
	command, ok := hub_adapter_command_from_record(record)
	if !ok do return false
	result := message_service_execute(command)
	if !result.ok do return false
	central_hub_ack(record.user_id, record.namespace, record.record_id)
	return true
}

// Compatibility with the old router route name: encrypted inbound records still converge through Command.
router_adapter_command_from_envelope :: proc(envelope: re.Router_Envelope, user_token: string) -> (Command, bool) {
	crypto := re.decrypt_payload_from_router(envelope.encrypted_payload_json, user_token)
	if !crypto.ok do return Command{}, false
	if envelope.payload_type == re.PAYLOAD_MESSAGE_SEND {
		payload, ok := re.parse_message_send_payload_json(crypto.payload_json)
		if !ok do return Command{}, false
		return Command{source = .Remote_Router_Envelope, kind = .Send_Message, send_message = Send_Message_Command{from_agent_instance_id = contracts.Agent_Instance_ID(payload.from_agent_instance_id), target_agent_instance_id = contracts.Agent_Instance_ID(payload.target_agent_instance_id), payload = payload.body}}, true
	}
	return Command{}, false
}
