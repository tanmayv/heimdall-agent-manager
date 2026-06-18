package main

import "core:fmt"
import "core:strings"
import "core:time"

HUB_MAX_RECORDS :: 8192
HUB_MAX_DEDUPE :: 8192
HUB_DEDUPE_TTL_MS :: i64(10 * 60 * 1000)

Hub_Record_Kind :: enum {
	Message_Send,
	Message_Read,
	Status,
	Presence,
}

Hub_Record :: struct {
	record_id: string,
	record_seq: i64,
	message_id: string,
	kind: Hub_Record_Kind,
	user_id: string,
	namespace: string,
	source_daemon_id: string,
	target_agent_instance_id: string,
	payload_type: string,
	payload_version: int,
	encrypted_payload_json: string,
	acked: bool,
	created_unix_ms: i64,
}

Hub_Presence :: struct {
	user_id: string,
	namespace: string,
	daemon_id: string,
	agent_instance_id: string,
	status: string,
	last_seen_unix_ms: i64,
}

Hub_Dedupe_Key :: struct {
	key: string,
	seen_unix_ms: i64,
}

hub_records: [HUB_MAX_RECORDS]Hub_Record
hub_record_count: int
hub_next_seq: i64
hub_seen_records: [HUB_MAX_DEDUPE]Hub_Dedupe_Key
hub_seen_record_count: int
hub_seen_messages: [HUB_MAX_DEDUPE]Hub_Dedupe_Key
hub_seen_message_count: int
hub_presence: [HUB_MAX_RECORDS]Hub_Presence
hub_presence_count: int

central_hub_init :: proc() {
	hub_record_count = 0
	hub_next_seq = 1
	hub_seen_record_count = 0
	hub_seen_message_count = 0
	hub_presence_count = 0
}

central_hub_append :: proc(record: Hub_Record) -> (Hub_Record, bool) {
	rec := record
	if rec.user_id == "" || rec.namespace == "" || rec.encrypted_payload_json == "" do return Hub_Record{}, false
	now := router_now_unix_ms()
	record_id := rec.record_id
	if record_id == "" do record_id = fmt.tprintf("hubrec_%d", hub_next_seq)
	message_id := rec.message_id
	if message_id == "" do message_id = record_id
	logical_dedupe_key := hub_logical_dedupe_key(rec.kind, message_id, rec.target_agent_instance_id)
	if hub_dedupe_seen_or_add(hub_seen_records[:], &hub_seen_record_count, record_id, now) do return rec, true
	if hub_dedupe_seen_or_add(hub_seen_messages[:], &hub_seen_message_count, logical_dedupe_key, now) do return rec, true
	if hub_record_count >= HUB_MAX_RECORDS do return Hub_Record{}, false
	rec.record_id = strings.clone(record_id)
	rec.message_id = strings.clone(message_id)
	rec.record_seq = hub_next_seq
	rec.created_unix_ms = now
	hub_next_seq += 1
	hub_records[hub_record_count] = rec
	hub_record_count += 1
	return rec, true
}

central_hub_poll :: proc(user_id, namespace: string, after_seq: i64, limit: int) -> []Hub_Record {
	max_results := limit
	if max_results <= 0 || max_results > 100 do max_results = 100
	result := make([dynamic]Hub_Record, 0, max_results)
	for i in 0..<hub_record_count {
		record := hub_records[i]
		if record.user_id != user_id || record.namespace != namespace do continue
		if record.record_seq <= after_seq do continue
		if record.acked do continue
		append(&result, record)
		if len(result) >= max_results do break
	}
	return result[:]
}

central_hub_ack :: proc(user_id, namespace, record_id: string) -> bool {
	for i in 0..<hub_record_count {
		if hub_records[i].user_id == user_id && hub_records[i].namespace == namespace && hub_records[i].record_id == record_id {
			hub_records[i].acked = true
			return true
		}
	}
	return false
}

central_hub_presence :: proc(user_id, namespace, daemon_id, agent_instance_id, status: string) -> bool {
	if user_id == "" || namespace == "" || daemon_id == "" do return false
	now := router_now_unix_ms()
	for i in 0..<hub_presence_count {
		p := hub_presence[i]
		if p.user_id == user_id && p.namespace == namespace && p.daemon_id == daemon_id && p.agent_instance_id == agent_instance_id {
			hub_presence[i].status = strings.clone(status)
			hub_presence[i].last_seen_unix_ms = now
			return true
		}
	}
	if hub_presence_count >= HUB_MAX_RECORDS do return false
	hub_presence[hub_presence_count] = Hub_Presence{user_id = strings.clone(user_id), namespace = strings.clone(namespace), daemon_id = strings.clone(daemon_id), agent_instance_id = strings.clone(agent_instance_id), status = strings.clone(status), last_seen_unix_ms = now}
	hub_presence_count += 1
	return true
}

hub_logical_dedupe_key :: proc(kind: Hub_Record_Kind, message_id, target_agent_instance_id: string) -> string {
	// Message send and message read records can legitimately share the same logical message_id.
	// Dedupe within each record kind so retries are idempotent without dropping read receipts.
	return fmt.tprintf("%v:%s:%s", kind, message_id, target_agent_instance_id)
}

router_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}

hub_dedupe_seen_or_add :: proc(keys: []Hub_Dedupe_Key, count: ^int, key: string, now: i64) -> bool {
	oldest_idx := 0
	oldest_seen := now
	for i in 0..<count^ {
		if now - keys[i].seen_unix_ms > HUB_DEDUPE_TTL_MS {
			keys[i] = Hub_Dedupe_Key{key = strings.clone(key), seen_unix_ms = now}
			return false
		}
		if keys[i].key == key do return true
		if keys[i].seen_unix_ms < oldest_seen {
			oldest_seen = keys[i].seen_unix_ms
			oldest_idx = i
		}
	}
	if count^ < len(keys) {
		keys[count^] = Hub_Dedupe_Key{key = strings.clone(key), seen_unix_ms = now}
		count^ += 1
		return false
	}
	keys[oldest_idx] = Hub_Dedupe_Key{key = strings.clone(key), seen_unix_ms = now}
	return false
}
