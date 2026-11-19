// Synchronous JetStream only. Callers must never invoke network procs while
// holding a SQLite transaction. No nats.c thread calls Odin.
// C-owned opaque handles are explicitly destroyed; returned views are borrowed.
package nats

import "core:c"
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
Stream_Config :: struct {
	name:                string,
	subjects:            []string,
	max_age_ns:          i64,
	duplicate_window_ns: i64,
	replicas:            i64,
	allow_rollup:        bool,
	allow_direct:        bool,
}
Consumer_Config :: struct {
	stream, durable:          string,
	filter_subjects:          []string,
	ack_wait_ns, max_deliver: i64,
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
	rollup: c.int
	if cfg.allow_rollup do rollup = 1
	direct: c.int
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
		rollup,
		direct,
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
		cfg.max_deliver,
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

// Read-only snapshots for notification decisions. Message ownership is the
// same as stream_get: caller destroys a successful result.
Consumer_State :: struct {
	delivered, pending, ack_pending: u64,
}
consumer_state :: proc(conn: ^Connection, stream, name: string) -> (state: Consumer_State, err: Error) {
	if conn == nil || stream == "" || name == "" || !valid_string(stream) || !valid_string(name) do return {}, {status = INVALID}
	a := strings.clone_to_cstring(stream); defer delete(a)
	b := strings.clone_to_cstring(name); defer delete(b)
	err.status = ham_nats_consumer_state(conn, a, b, &state, &err.jetstream)
	return
}
stream_next :: proc(
	conn: ^Connection,
	stream, subject: string,
	sequence: u64,
) -> (
	msg: ^Message,
	actual: u64,
	err: Error,
) {
	if conn == nil || stream == "" || subject == "" || !valid_string(stream) || !valid_string(subject) do return nil, 0, {status = INVALID}
	a := strings.clone_to_cstring(stream); defer delete(a)
	b := strings.clone_to_cstring(subject); defer delete(b)
	err.status = ham_nats_stream_next(&msg, conn, a, b, sequence, &actual)
	return
}
