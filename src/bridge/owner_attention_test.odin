package main

import "core:testing"
import owner "odin_test:lib/owner_local"

@(test)
test_owner_attention_frame_carries_ids_and_flags_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, bridge_owner_attention_frame(nil), `{"type":"owner_attention","protocol_version":1,"items":[]}`)
	items := []owner.User_Attention{
		{"chain_a", "T-1", "blocked", "question", "ready", "1"},
		{"chain_a", "T-2", "review", "review", "in_review", "2"},
	}
	testing.expect_value(t, bridge_owner_attention_frame(items),
		`{"type":"owner_attention","protocol_version":1,"items":[` +
		`{"chain_id":"chain_a","task_id":"T-1","attention":"blocked","badge":"question","state":"ready","attempt":"1"},` +
		`{"chain_id":"chain_a","task_id":"T-2","attention":"review","badge":"review","state":"in_review","attempt":"2"}]}`)
}
