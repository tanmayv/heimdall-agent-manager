package events

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

User_Event_Bus :: struct {
	owner_user_ids: [128]string,
	sockets: [128]net.TCP_Socket,
	connected: [128]bool,
	client_count: int,
	event_seq: int,
}

user_ws_add :: proc(bus: ^User_Event_Bus, owner_user_id: string, socket: net.TCP_Socket) -> int {
	if bus == nil || owner_user_id == "" do return -1
	for i in 0..<len(bus.connected) {
		if !bus.connected[i] {
			bus.connected[i] = true
			bus.owner_user_ids[i] = owner_user_id
			bus.sockets[i] = socket
			if i >= bus.client_count do bus.client_count = i + 1
			return i
		}
	}
	return -1
}

user_ws_remove :: proc(bus: ^User_Event_Bus, idx: int) {
	if bus == nil || idx < 0 || idx >= len(bus.connected) do return
	bus.connected[idx] = false
	bus.owner_user_ids[idx] = ""
	bus.sockets[idx] = net.TCP_Socket(0)
}

publish_resource_changed :: proc(bus: ^User_Event_Bus, owner_user_id, resource, resource_id, change, summary_json: string) {
	if bus == nil || owner_user_id == "" do return
	bus.event_seq += 1
	event := resource_changed_json(bus.event_seq, resource, resource_id, change, summary_json)
	publish_raw_to_user(bus, owner_user_id, event)
}

publish_raw_to_user :: proc(bus: ^User_Event_Bus, owner_user_id, event_json: string) {
	if bus == nil || owner_user_id == "" || event_json == "" do return
	for i in 0..<bus.client_count {
		if bus.connected[i] && bus.owner_user_ids[i] == owner_user_id {
			if !write_ws_text_frame(bus.sockets[i], event_json) do user_ws_remove(bus, i)
		}
	}
}

resource_changed_json :: proc(seq: int, resource, resource_id, change, summary_json: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"type\":\"resource_changed\",\"event_id\":\"evt_")
	strings.write_string(&b, fmt.tprintf("%d", seq))
	strings.write_string(&b, "\",\"resource\":\""); write_json_string(&b, resource)
	strings.write_string(&b, "\",\"resource_id\":\""); write_json_string(&b, resource_id)
	strings.write_string(&b, "\",\"change\":\""); write_json_string(&b, change)
	strings.write_string(&b, "\",\"version\":"); strings.write_string(&b, fmt.tprintf("%d", seq))
	if summary_json != "" { strings.write_string(&b, ",\"summary\":"); strings.write_string(&b, summary_json) }
	strings.write_string(&b, ",\"occurred_at\":\""); strings.write_string(&b, fmt.tprintf("%d", time.to_unix_nanoseconds(time.now())))
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

write_ws_text_frame :: proc(socket: net.TCP_Socket, text: string) -> bool {
	n := len(text)
	if n > 65535 do return false
	header_len := 2
	if n > 125 do header_len = 4
	frame := make([]byte, header_len + n)
	frame[0] = 0x81
	if n <= 125 { frame[1] = byte(n) } else { frame[1] = 126; frame[2] = byte((n >> 8) & 0xff); frame[3] = byte(n & 0xff) }
	copy(frame[header_len:], transmute([]byte)text)
	_, err := net.send_tcp(socket, frame)
	return err == nil
}

write_json_string :: proc(b: ^strings.Builder, value: string) {
	contracts.write_json_string(b, value)
}
