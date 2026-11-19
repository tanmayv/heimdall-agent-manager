package nats

import "core:c"

// Built by nix/nats.nix or scripts/windows/build-nats.ps1.
// Nix shares OpenSSL with httpc; Windows httpc uses Schannel.
when ODIN_OS == .Windows {
	foreign import client {"system:ham_nats.lib", "system:nats_static.lib", "system:ssl.lib", "system:crypto.lib"}
} else {
	foreign import client {"system:ham_nats", "system:nats_static", "system:ssl", "system:crypto"}
}
@(private)
foreign client {
	ham_nats_connect :: proc(out: ^^Connection, url, creds, ca: cstring, timeout_ms: i64) -> i32 ---
	ham_nats_destroy :: proc(conn: ^Connection) ---
	ham_nats_publish :: proc(conn: ^Connection, subject: cstring, data: rawptr, size: c.int, id: cstring, keys, values: [^]cstring, count: c.int, out: ^Pub_Ack, js_error: ^i32) -> i32 ---
	ham_nats_stream :: proc(conn: ^Connection, operation: c.int, name: cstring, subjects: [^]cstring, count: c.int, age, duplicates, replicas: i64, rollup: c.int, out: ^Stream_State, js_error: ^i32) -> i32 ---
	ham_nats_consumer_add :: proc(conn: ^Connection, stream, durable: cstring, filters: [^]cstring, count: c.int, ack_wait, max_deliver: i64, js_error: ^i32) -> i32 ---
	ham_nats_consumer_delete :: proc(conn: ^Connection, stream, durable: cstring, js_error: ^i32) -> i32 ---
	ham_nats_pull_bind :: proc(out: ^^Pull, conn: ^Connection, stream, durable: cstring, js_error: ^i32) -> i32 ---
	ham_nats_pull_destroy :: proc(pull: ^Pull) ---
	ham_nats_fetch :: proc(out: ^^Batch, pull: ^Pull, count: c.int, timeout_ms: i64, js_error: ^i32) -> i32 ---
	ham_nats_batch_destroy :: proc(batch: ^Batch) ---
	ham_nats_batch_count :: proc(batch: ^Batch) -> c.int ---
	ham_nats_batch_message :: proc(batch: ^Batch, index: c.int) -> ^Message ---
	ham_nats_metadata :: proc(msg: ^Message, out: ^Metadata) -> i32 ---
	ham_nats_ack :: proc(msg: ^Message, js_error: ^i32) -> i32 ---
	ham_nats_nak :: proc(msg: ^Message) -> i32 ---
	ham_nats_term :: proc(msg: ^Message) -> i32 ---
	natsMsg_GetData :: proc(msg: ^Message) -> rawptr ---
	natsMsg_GetDataLength :: proc(msg: ^Message) -> c.int ---
	natsMsg_GetSubject :: proc(msg: ^Message) -> cstring ---
	natsMsgHeader_Get :: proc(msg: ^Message, key: cstring, out: ^cstring) -> i32 ---
	ham_nats_version :: proc() -> cstring ---
	natsStatus_GetText :: proc(status: i32) -> cstring ---
	nats_CloseAndWait :: proc(timeout_ms: i64) -> i32 ---
}
