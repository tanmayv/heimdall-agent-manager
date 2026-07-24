package main

import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

Bridge_Local_Token_Role :: enum {
	Agent,
	Wrapper,
}

Bridge_Local_Agent_Token_Record :: struct {
	token_hash: string,
	agent_instance_id: string,
	instance_token: string, // Hub credential: Bridge-held only, never returned to wrapper/agent.
	role: Bridge_Local_Token_Role,
	issued_at_unix_ms: i64,
	rotated_at_unix_ms: i64,
	invalidated_at_unix_ms: i64,
}

Bridge_Local_Token_Issue_Result :: struct {
	endpoint: string,
	plaintext_token: string,
	agent_instance_id: string,
	role: Bridge_Local_Token_Role,
}

bridge_local_token_mutex: sync.Mutex
bridge_local_token_records: [dynamic]Bridge_Local_Agent_Token_Record
bridge_local_token_sequence: i64

bridge_agent_token_store_init :: proc() {
	bridge_local_token_mutex = sync.Mutex{}
	bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record)
	bridge_local_token_sequence = 0
}

bridge_agent_token_issue :: proc(agent_instance_id, instance_token: string, role: Bridge_Local_Token_Role) -> Bridge_Local_Token_Issue_Result {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	plain := bridge_local_generate_token("hlat_")
	now := bridge_local_now_unix_ms()
	record := Bridge_Local_Agent_Token_Record{
		token_hash = bridge_local_hash_token(plain),
		agent_instance_id = strings.clone(strings.trim_space(agent_instance_id)),
		instance_token = strings.clone(strings.trim_space(instance_token)),
		role = role,
		issued_at_unix_ms = now,
	}
	sync.mutex_lock(&bridge_local_token_mutex)
	append(&bridge_local_token_records, record)
	sync.mutex_unlock(&bridge_local_token_mutex)
	return Bridge_Local_Token_Issue_Result{plaintext_token = plain, agent_instance_id = record.agent_instance_id, role = role}
}

bridge_agent_token_verify :: proc(plaintext: string) -> (Bridge_Local_Agent_Token_Record, bool) {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	hash := bridge_local_hash_token(strings.trim_space(plaintext))
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for rec in bridge_local_token_records {
		if rec.token_hash == hash && rec.invalidated_at_unix_ms == 0 {
			return rec, true
		}
	}
	return {}, false
}

bridge_agent_token_rotate :: proc(plaintext: string) -> (Bridge_Local_Token_Issue_Result, bool) {
	rec, ok := bridge_agent_token_verify(plaintext)
	if !ok do return {}, false
	_ = bridge_agent_token_invalidate(plaintext)
	result := bridge_agent_token_issue(rec.agent_instance_id, rec.instance_token, rec.role)
	return result, true
}

bridge_agent_token_invalidate :: proc(plaintext: string) -> bool {
	if bridge_local_token_records == nil do bridge_agent_token_store_init()
	hash := bridge_local_hash_token(strings.trim_space(plaintext))
	now := bridge_local_now_unix_ms()
	sync.mutex_lock(&bridge_local_token_mutex)
	defer sync.mutex_unlock(&bridge_local_token_mutex)
	for i in 0..<len(bridge_local_token_records) {
		if bridge_local_token_records[i].token_hash == hash && bridge_local_token_records[i].invalidated_at_unix_ms == 0 {
			bridge_local_token_records[i].invalidated_at_unix_ms = now
			return true
		}
	}
	return false
}

bridge_local_token_role_string :: proc(role: Bridge_Local_Token_Role) -> string {
	switch role {
	case .Agent: return "agent"
	case .Wrapper: return "wrapper"
	}
	return "agent"
}

bridge_local_generate_token :: proc(prefix: string) -> string {
	sync.mutex_lock(&bridge_local_token_mutex)
	bridge_local_token_sequence += 1
	seq := bridge_local_token_sequence
	sync.mutex_unlock(&bridge_local_token_mutex)
	return fmt.tprintf("%s%x_%d", prefix, time.to_unix_nanoseconds(time.now()), seq)
}

bridge_local_hash_token :: proc(token: string) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)token)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	builder := strings.builder_make()
	strings.write_string(&builder, "sha1:")
	for b in digest do bridge_local_write_hex_byte(&builder, b)
	return strings.to_string(builder)
}

bridge_local_write_hex_byte :: proc(builder: ^strings.Builder, value: byte) {
	strings.write_byte(builder, bridge_local_hex_digit(value >> 4))
	strings.write_byte(builder, bridge_local_hex_digit(value & 0x0f))
}

bridge_local_hex_digit :: proc(n: byte) -> byte {
	if n < 10 do return '0' + n
	return 'a' + (n - 10)
}

bridge_local_now_unix_ms :: proc() -> i64 {
	return time.to_unix_nanoseconds(time.now()) / 1_000_000
}
