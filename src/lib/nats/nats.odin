// Synchronous JetStream only. Callers must never invoke network procs while
// holding a SQLite transaction. No nats.c thread calls Odin.
// C-owned opaque handles are explicitly destroyed; returned views are borrowed.
package nats

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Connection :: struct {}
Pull :: struct {}
Batch :: struct {}
Message :: struct {}
Error :: struct {
	status, jetstream: i32,
}
Pub_Ack :: struct {
	sequence:  u64,
	duplicate: c.int,
}
Stream_State :: struct {
	messages, first, last: u64,
}
Metadata :: struct {
	stream_sequence, consumer_sequence, num_delivered, num_pending: u64,
	timestamp_ns: i64,
}
Header :: struct {
	key, value: string,
}
Connect_Options :: struct {
	url:        string,
	creds_file: string,
	ca_file:    string,
	timeout_ms: i64,
}
Retention :: enum i32 { Limits = 0, Work_Queue = 1 }
Stream_Config :: struct {
	name:                string,
	subjects:            []string,
	max_age_ns:          i64,
	duplicate_window_ns: i64,
	replicas:            i64,
	allow_rollup:        bool,
	allow_direct:        bool,
	allow_msg_schedules, allow_msg_ttl: bool,
	retention: Retention,
}
Consumer_Config :: struct {
	stream, durable:          string,
	filter_subjects:          []string,
	ack_wait_ns, max_deliver: i64,
	deliver_new: bool,
	max_ack_pending: i64,
}
@(private)
INVALID :: i32(16) // NATS_INVALID_ARG (natsStatus)

// Returns the linked client version as a borrowed static string; never free.
version :: proc "contextless" () -> string {return string(ham_nats_version())}

// Returns a borrowed static status description; never free it.
error_text :: proc(err: Error) -> string {return string(natsStatus_GetText(err.status))}

// Borrows all options for the call. Success transfers a C handle to the caller,
// who must destroy it after all pulls and batches obtained from it are destroyed.
connect :: proc(opts: Connect_Options) -> (conn: ^Connection, err: Error) {
	if opts.url == "" ||
	   opts.timeout_ms <= 0 ||
	   !valid_string(opts.url) ||
	   !valid_string(opts.creds_file) ||
	   !valid_string(opts.ca_file) {
		return nil, Error{status = INVALID}
	}
	url := strings.clone_to_cstring(opts.url)
	defer delete(url)
	creds := strings.clone_to_cstring(opts.creds_file)
	defer delete(creds)
	ca := strings.clone_to_cstring(opts.ca_file)
	defer delete(ca)
	err.status = ham_nats_connect(&conn, url, creds, ca, opts.timeout_ms)
	return
}

// Releases the C connection and JetStream context; nil is safe. Not concurrent
// with any operation on the handle. Destroy pulls/batches first.
destroy :: proc(conn: ^Connection) {ham_nats_destroy(conn)}

// Global process shutdown: call only after ALL handles are destroyed and all
// callers have stopped. Waits for nats.c's internal threads; owns no Odin memory.
shutdown :: proc(timeout_ms: i64) -> Error {return Error{status = nats_CloseAndWait(timeout_ms)}}

// Borrows payload/headers for the call; returns a value copy of PubAck.
// All temporary messages and the C PubAck are destroyed on success and failure.
publish :: proc(
	conn: ^Connection,
	subject: string,
	payload: []byte,
	msg_id := "",
	headers: []Header = nil,
) -> (
	ack: Pub_Ack,
	err: Error,
) {
	if conn == nil ||
	   subject == "" ||
	   !valid_string(subject) ||
	   !valid_string(msg_id) ||
	   len(payload) > 0x7fffffff ||
	   len(headers) > 0x7fffffff {
		return ack, Error{status = INVALID}
	}
	for h in headers {
		if h.key == "" || !valid_string(h.key) || !valid_string(h.value) {
			return ack, Error{status = INVALID}
		}
	}
	subj := strings.clone_to_cstring(subject)
	defer delete(subj)
	id := strings.clone_to_cstring(msg_id)
	defer delete(id)
	keys := make([]cstring, len(headers))
	defer delete(keys)
	values := make([]cstring, len(headers))
	defer delete(values)
	for h, i in headers {
		keys[i] = strings.clone_to_cstring(h.key)
		values[i] = strings.clone_to_cstring(h.value)
	}
	defer for i in 0 ..< len(headers) {delete(keys[i]); delete(values[i])}
	err.status = ham_nats_publish(
		conn,
		subj,
		raw_data(payload),
		c.int(len(payload)),
		id,
		raw_data(keys),
		raw_data(values),
		c.int(len(headers)),
		&ack,
		&err.jetstream,
	)
	return
}

// Borrows config for the call; returns copied state. Destroys C stream info.
stream_add :: proc(conn: ^Connection, config: Stream_Config) -> (Stream_State, Error) {return stream_operation(
		conn,
		config,
		0,
	)}
// Same ownership as stream_add; replaces the server's stream configuration.
stream_update :: proc(conn: ^Connection, config: Stream_Config) -> (Stream_State, Error) {return stream_operation(
		conn,
		config,
		1,
	)}
// Borrows name; returns copied state. Destroys C stream info.
stream_info :: proc(conn: ^Connection, name: string) -> (Stream_State, Error) {return stream_operation(
		conn,
		Stream_Config{name = name},
		2,
	)}

@(private)
stream_operation :: proc(conn: ^Connection, cfg: Stream_Config, op: c.int) -> (state: Stream_State, err: Error) {
	if conn == nil ||
	   cfg.name == "" ||
	   !valid_string(cfg.name) ||
	   !valid_strings(cfg.subjects) ||
	   (op != 2 &&
			   (len(cfg.subjects) == 0 || cfg.replicas <= 0 || cfg.max_age_ns < 0 || cfg.duplicate_window_ns < 0)) {
		return state, Error{status = INVALID}
	}
	name := strings.clone_to_cstring(cfg.name)
	defer delete(name)
	subjects := clone_cstrings(cfg.subjects)
	defer destroy_cstrings(subjects)
	rollup, direct: c.int
	if cfg.allow_rollup do rollup = 1
	if cfg.allow_direct do direct = 1
	err.status = ham_nats_stream(
		conn,
		op,
		name,
		raw_data(subjects),
		c.int(len(subjects)),
		cfg.max_age_ns,
		cfg.duplicate_window_ns,
		cfg.replicas,
		rollup, direct, c.int(cfg.allow_msg_schedules), c.int(cfg.allow_msg_ttl), c.int(cfg.retention),
		&state,
		&err.jetstream,
	)
	return
}

// Borrows config; creates a durable explicit-ack pull consumer. No C info escapes.
consumer_add :: proc(conn: ^Connection, cfg: Consumer_Config) -> (err: Error) {
	if conn == nil ||
	   !valid_name(cfg.stream) ||
	   !valid_name(cfg.durable) ||
	   !valid_strings(cfg.filter_subjects) ||
	   cfg.ack_wait_ns <= 0 ||
	   cfg.max_deliver <= 0 {
		return Error{status = INVALID}
	}
	stream := strings.clone_to_cstring(cfg.stream)
	defer delete(stream)
	durable := strings.clone_to_cstring(cfg.durable)
	defer delete(durable)
	filters := clone_cstrings(cfg.filter_subjects)
	defer destroy_cstrings(filters)
	err.status = ham_nats_consumer_add(
		conn,
		stream,
		durable,
		raw_data(filters),
		c.int(len(filters)),
		cfg.ack_wait_ns,
		cfg.max_deliver, c.int(cfg.deliver_new), cfg.max_ack_pending,
		&err.jetstream,
	)
	return
}

// Borrows names; deletes the durable server consumer, not local Pull handles.
consumer_delete :: proc(conn: ^Connection, stream, durable: string) -> (err: Error) {
	if conn == nil || !valid_name(stream) || !valid_name(durable) do return Error{status = INVALID}
	s := strings.clone_to_cstring(stream)
	defer delete(s)
	d := strings.clone_to_cstring(durable)
	defer delete(d)
	err.status = ham_nats_consumer_delete(conn, s, d, &err.jetstream)
	return
}

// Binds an existing consumer. Caller owns the returned Pull and must call
// pull_destroy before destroying conn; local destruction preserves the durable.
pull_bind :: proc(conn: ^Connection, stream, durable: string) -> (pull: ^Pull, err: Error) {
	if conn == nil || !valid_name(stream) || !valid_name(durable) do return nil, Error{status = INVALID}
	s := strings.clone_to_cstring(stream)
	defer delete(s)
	d := strings.clone_to_cstring(durable)
	defer delete(d)
	err.status = ham_nats_pull_bind(&pull, conn, s, d, &err.jetstream)
	return
}

// Releases local C subscription; nil is safe. Does not delete server consumer.
pull_destroy :: proc(pull: ^Pull) {ham_nats_pull_destroy(pull)}

// Success transfers a C Batch (and all contained messages) to caller. Always
// batch_destroy before pull_destroy; failure returns nil with no partial batch.
fetch :: proc(pull: ^Pull, limit: int, timeout_ms: i64) -> (batch: ^Batch, err: Error) {
	if pull == nil || limit <= 0 || limit > 0x7fffffff || timeout_ms <= 0 do return nil, Error{status = INVALID}
	err.status = ham_nats_fetch(&batch, pull, c.int(limit), timeout_ms, &err.jetstream)
	return
}

// Destroys all C messages and list storage; invalidates all borrowed views.
batch_destroy :: proc(batch: ^Batch) {ham_nats_batch_destroy(batch)}
// Borrows batch; returns a scalar, zero for nil.
batch_count :: proc(batch: ^Batch) -> int {if batch == nil do return 0; return int(ham_nats_batch_count(batch))}
// Borrows batch; returns borrowed message, nil if out of range. Never free it.
batch_message :: proc(batch: ^Batch, index: int) -> ^Message {
	if batch == nil || index < 0 || index >= batch_count(batch) do return nil
	return ham_nats_batch_message(batch, c.int(index))
}
// Returns a borrowed payload view valid until batch_destroy; never free/mutate.
message_data :: proc(msg: ^Message) -> []byte {
	if msg == nil do return nil
	return ([^]byte)(natsMsg_GetData(msg))[:int(natsMsg_GetDataLength(msg))]
}
// Returns borrowed subject valid until batch_destroy; never free it.
message_subject :: proc(msg: ^Message) -> string {if msg == nil do return ""; return string(natsMsg_GetSubject(msg))}
// Borrows key; returns first matching header as a borrowed view until
// batch_destroy. Missing header returns nonzero status and empty value.
message_header :: proc(msg: ^Message, key: string) -> (value: string, err: Error) {
	if msg == nil || !valid_name(key) do return "", Error{status = INVALID}
	k := strings.clone_to_cstring(key)
	defer delete(k)
	v: cstring
	err.status = natsMsgHeader_Get(msg, k, &v)
	if err.status == 0 do value = string(v)
	return
}
// Returns copied metadata; C metadata is destroyed before returning.
message_metadata :: proc(msg: ^Message) -> (meta: Metadata, err: Error) {
	if msg == nil do return meta, Error{status = INVALID}
	err.status = ham_nats_metadata(msg, &meta)
	return
}
// Borrows message; synchronous server-confirmed ack. Does not destroy message.
ack :: proc(msg: ^Message) -> (err: Error) {
	if msg == nil do return Error{status = INVALID}
	err.status = ham_nats_ack(msg, &err.jetstream)
	return
}
// Borrows message; queues negative ack for immediate redelivery; retains message.
nak :: proc(msg: ^Message) -> Error {
	if msg == nil do return Error{status = INVALID}
	return Error{status = ham_nats_nak(msg)}
}
// Borrows message; queues terminal ack (no more redelivery); retains message.
term :: proc(msg: ^Message) -> Error {
	if msg == nil do return Error{status = INVALID}
	return Error{status = ham_nats_term(msg)}
}

@(private)
valid_string :: proc(s: string) -> bool {return !strings.contains(s, "\x00")}
@(private)
valid_name :: proc(s: string) -> bool {return s != "" && valid_string(s)}
@(private)
valid_strings :: proc(values: []string) -> bool {
	if len(values) > 0x7fffffff do return false
	for s in values {if !valid_name(s) do return false}
	return true
}
@(private)
clone_cstrings :: proc(values: []string) -> []cstring {
	result := make([]cstring, len(values))
	for s, i in values do result[i] = strings.clone_to_cstring(s)
	return result
}
@(private)
destroy_cstrings :: proc(values: []cstring) {for s in values do delete(s); delete(values)}

// Reply is borrowed until the message/batch is destroyed. Clone before storing.
message_reply :: proc(msg: ^Message) -> string {
	if msg == nil do return ""
	return string(natsMsg_GetReply(msg))
}
// Only pass reply subjects read from an authenticated subscriber's stored
// delivery. This is synchronous and must run outside a SQLite UoW.
ack_reply :: proc(conn: ^Connection, reply: string, timeout_ms: i64) -> Error {
	if conn == nil || !valid_name(reply) || timeout_ms <= 0 do return Error{status = INVALID}
	value := strings.clone_to_cstring(reply)
	defer delete(value)
	return Error{status = ham_nats_ack_reply(conn, value, timeout_ms)}
}
stream_get :: proc(conn: ^Connection, stream: string, sequence: u64) -> (msg: ^Message, err: Error) {
	if conn == nil || !valid_name(stream) || sequence == 0 do return nil, Error{status = INVALID}
	value := strings.clone_to_cstring(stream)
	defer delete(value)
	err.status = ham_nats_stream_get(&msg, conn, value, sequence, &err.jetstream)
	return
}
message_destroy :: proc(msg: ^Message) {natsMsg_Destroy(msg)}

// Snapshot of the server/account JetStream API counters, including this INFO
// request. Used to verify idle inbox traffic against the real server.
api_stats :: proc(conn: ^Connection) -> (total, errors: u64, err: Error) {
	if conn == nil do return 0, 0, Error{status = INVALID}
	err.status = ham_nats_api_stats(conn, &total, &errors, &err.jetstream)
	return
}

// Server-side NoWait fetch: promptly reads available messages without imposing
// an unsafe millisecond client deadline. Ownership matches fetch.
fetch_available :: proc(pull: ^Pull, limit: int) -> (batch: ^Batch, err: Error) {
	if pull == nil || limit <= 0 || limit > 0x7fffffff do return nil, Error{status = INVALID}
	err.status = ham_nats_fetch_available(&batch, pull, c.int(limit), &err.jetstream)
	return
}

Consumer_State :: struct {
	delivered, pending, ack_pending, redelivered: u64,
}
consumer_state :: proc(conn: ^Connection, stream, name: string) -> (state: Consumer_State, err: Error) {
	if conn == nil || stream == "" || name == "" || !valid_string(stream) || !valid_string(name) do return {}, {status = INVALID}
	a := strings.clone_to_cstring(stream); defer delete(a)
	b := strings.clone_to_cstring(name); defer delete(b)
	err.status = ham_nats_consumer_state(conn, a, b, &state, &err.jetstream)
	return
}

subject_count :: proc(conn: ^Connection, stream, filter: string) -> (count: u64, err: Error) {
	if conn == nil || !valid_name(stream) || !valid_string(filter) || filter == "" do return 0, Error{status = INVALID}
	s := strings.clone_to_cstring(stream); defer delete(s)
	f := strings.clone_to_cstring(filter); defer delete(f)
	err.status = ham_nats_subject_count(conn, s, f, &count, &err.jetstream)
	return
}

// Returns the first message matching filter at or after start. A nil message
// with NATS_NOT_FOUND (status 13) means no match. Caller owns a successful message.
stream_next :: proc(conn: ^Connection, stream, filter: string, start: u64) -> (msg: ^Message, sequence: u64, err: Error) {
	if conn == nil || !valid_name(stream) || filter == "" || !valid_string(filter) || start == 0 do return nil, 0, Error{status = INVALID}
	s := strings.clone_to_cstring(stream); defer delete(s)
	f := strings.clone_to_cstring(filter); defer delete(f)
	err.status = ham_nats_stream_next(&msg, conn, s, f, start, &sequence)
	return
}

// A subject token is shared by tenant filters and schedule/delivery subjects.
subject_token :: proc(value: string) -> bool {
	if value == "" do return false
	for c in value {
		if c <= ' ' || c == '.' || c == '*' || c == '>' || c == 127 do return false
	}
	return true
}

version_at_least :: proc(version: string, major, minor, patch: int) -> bool {
	core := version
	if i := strings.index_byte(core, '-'); i >= 0 do core = core[:i]
	values: [3]int
	part := 0
	digits := 0
	for c in core {
		if c == '.' {
			if digits == 0 || part >= 2 do return false
			part += 1
			digits = 0
		} else {
			if c < '0' || c > '9' do return false
			digit := int(c - '0')
			if values[part] > (max(int) - digit) / 10 do return false
			values[part] = values[part] * 10 + digit
			digits += 1
		}
	}
	if part != 2 || digits == 0 do return false
	want := [3]int{major, minor, patch}
	for v, i in values {
		if v != want[i] do return v > want[i]
	}
	return true
}

// Reads _nats.ver while the C stream-info allocation is alive. No view escapes.
server_supports_schedules :: proc(conn: ^Connection, stream: string) -> (supported: bool, err: Error) {
	if conn == nil || !valid_name(stream) do return false, Error{status = INVALID}
	name := strings.clone_to_cstring(stream); defer delete(name)
	buffer: [128]u8
	err.status = ham_nats_server_version(conn, name, raw_data(buffer[:]), c.int(len(buffer)), &err.jetstream)
	if err.status != 0 do return false, err
	return version_at_least(string(cstring(raw_data(buffer[:]))), 2, 14, 0), err
}

// The raw API is needed because js_PurgeStream discards the server's count.
// Revision 2 requires the count from the same operation, never a preflight count.
stream_purge_subject :: proc(conn: ^Connection, stream, subject: string) -> (purged: u64, err: Error) {
	if conn == nil || !valid_name(stream) || subject == "" || !valid_string(subject) do return 0, Error{status = INVALID}
	for c in subject {
		if c <= ' ' || c == 127 || c == '*' || c == '>' do return 0, Error{status = INVALID}
	}
	payload, encode_err := json.marshal(struct {filter: string}{subject})
	if encode_err != nil do return 0, Error{status = INVALID}
	defer delete(payload)
	api := strings.clone_to_cstring(fmt.tprintf("$JS.API.STREAM.PURGE.%s", stream)); defer delete(api)
	msg: ^Message
	err.status = ham_nats_request(&msg, conn, api, raw_data(payload), c.int(len(payload)))
	if err.status != 0 do return
	defer message_destroy(msg)
	response: struct {
		success: bool,
		purged: u64,
		error: struct {code, err_code: i32},
	}
	decode_err := json.unmarshal(message_data(msg), &response)
	if decode_err != nil || !response.success || response.error.code != 0 {
		err = {status = 1, jetstream = response.error.err_code}
		return
	}
	return response.purged, err
}

// Plain protocol publishes do not wait for a reply and allocate nothing for callers.
@(private)
publish_reply :: proc(conn: ^Connection, reply, body: string) -> (err: Error) {
	if conn == nil || reply == "" || !valid_string(reply) do return Error{status = INVALID}
	r := strings.clone_to_cstring(reply); defer delete(r)
	err.status = ham_nats_publish_reply(conn, r, raw_data(body), c.int(len(body)))
	return
}
ack_reply_async :: proc(conn: ^Connection, reply: string) -> Error {return publish_reply(conn, reply, "+ACK")}
in_progress_reply :: proc(conn: ^Connection, reply: string) -> Error {return publish_reply(conn, reply, "+WPI")}
term_reply :: proc(conn: ^Connection, reply: string) -> Error {return publish_reply(conn, reply, "+TERM")}
nak_reply_delay :: proc(conn: ^Connection, reply: string, delay_ms: i64) -> Error {
	if delay_ms > max(i64) / 1_000_000 do return Error{status = INVALID}
	return publish_reply(conn, reply, fmt.tprintf("%s%d%s", "-NAK {\"delay\": ", max(delay_ms, 0) * 1_000_000, "}"))
}
stream_delete_message :: proc(conn: ^Connection, stream: string, sequence: u64) -> (deleted: bool, err: Error) {
	if conn == nil || !valid_name(stream) || sequence == 0 do return false, Error{status = INVALID}
	name := strings.clone_to_cstring(stream); defer delete(name)
	result: c.int
	err.status = ham_nats_delete_message(conn, name, sequence, &result, &err.jetstream)
	return result != 0, err
}

// A barrier for preceding asynchronous protocol publishes.
flush :: proc(conn: ^Connection) -> (err: Error) {
	if conn == nil do return Error{status = INVALID}
	err.status = ham_nats_flush(conn)
	return
}
