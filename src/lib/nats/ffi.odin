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
    // Private inspection seam: exercise the encoder in the actual linked client.
    nats_EncodeTimeUTC :: proc(buf: [^]u8, size: c.size_t, timestamp_ns: i64) -> i32 ---
 ham_nats_core_subscribe :: proc(out: ^^Core_Subscription, conn: ^Connection, subject: cstring) -> i32 ---
 natsSubscription_NextMsg :: proc(out: ^^Message, sub: ^Core_Subscription, timeout_ms: i64) -> i32 ---
 natsSubscription_Unsubscribe :: proc(sub: ^Core_Subscription) -> i32 ---
 natsSubscription_Destroy :: proc(sub: ^Core_Subscription) ---

    ham_nats_long_pull_bind :: proc(out: ^^Long_Pull, conn: ^Connection, stream, consumer: cstring) -> i32 ---
    ham_nats_long_pull_next :: proc(out: ^^Message, pull: ^Long_Pull, limit: c.int, wait_ms: i64, requested: ^c.int) -> i32 ---
    ham_nats_long_pull_destroy :: proc(pull: ^Long_Pull) ---

	ham_nats_delete_error_absent :: proc(status, code: i32, description: cstring) -> c.int ---
	ham_nats_server_version :: proc(conn: ^Connection, stream: cstring, out: ^u8, size: c.int, js_error: ^i32) -> i32 ---
	ham_nats_request :: proc(out: ^^Message, conn: ^Connection, subject: cstring, data: rawptr, size: c.int) -> i32 ---
	ham_nats_publish_reply :: proc(conn: ^Connection, reply: cstring, data: rawptr, size: c.int) -> i32 ---
	ham_nats_delete_message :: proc(conn: ^Connection, stream: cstring, sequence: u64, deleted: ^c.int, js_error: ^i32) -> i32 ---
	ham_nats_flush :: proc(conn: ^Connection) -> i32 ---

	ham_nats_stream_next :: proc(out: ^^Message, conn: ^Connection, stream, filter: cstring, start: u64, sequence: ^u64) -> i32 ---
	ham_nats_subject_count :: proc(conn: ^Connection, stream, filter: cstring, count: ^u64, js_error: ^i32) -> i32 ---
	ham_nats_consumer_state :: proc(conn: ^Connection, stream, consumer: cstring, out: ^Consumer_State, js_error: ^i32) -> i32 ---
	ham_nats_api_stats :: proc(conn: ^Connection, total, errors: ^u64, js_error: ^i32) -> i32 ---
	ham_nats_ack_reply :: proc(conn: ^Connection, reply: cstring, timeout_ms: i64) -> i32 ---
	ham_nats_stream_get :: proc(out: ^^Message, conn: ^Connection, stream: cstring, sequence: u64, js_error: ^i32) -> i32 ---
	natsMsg_GetReply :: proc(msg: ^Message) -> cstring ---
	natsMsg_Destroy :: proc(msg: ^Message) ---

	ham_nats_connect :: proc(out: ^^Connection, url, creds, ca: cstring, timeout_ms: i64) -> i32 ---
	ham_nats_destroy :: proc(conn: ^Connection) ---
	ham_nats_publish :: proc(conn: ^Connection, subject: cstring, data: rawptr, size: c.int, id: cstring, keys, values: [^]cstring, count: c.int, out: ^Pub_Ack, js_error: ^i32) -> i32 ---
	ham_nats_stream :: proc(conn: ^Connection, operation: c.int, name: cstring, subjects: [^]cstring, count: c.int, age, duplicates, replicas: i64, rollup, direct, schedules, ttl, retention: c.int, out: ^Stream_State, js_error: ^i32) -> i32 ---
	ham_nats_consumer_add :: proc(conn: ^Connection, stream, durable: cstring, filters: [^]cstring, count: c.int, ack_wait, max_deliver, start_time_ns: i64, deliver_new: c.int, max_ack_pending: i64, js_error: ^i32) -> i32 ---
	ham_nats_consumer_delete :: proc(conn: ^Connection, stream, durable: cstring, js_error: ^i32) -> i32 ---
	ham_nats_pull_bind :: proc(out: ^^Pull, conn: ^Connection, stream, durable: cstring, js_error: ^i32) -> i32 ---
	ham_nats_pull_destroy :: proc(pull: ^Pull) ---
	ham_nats_fetch_available :: proc(out: ^^Batch, pull: ^Pull, count: c.int, js_error: ^i32) -> i32 ---
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
