package nats

import server "../natstest"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Single root keeps global nats.c shutdown outside concurrent tests. Every
// scenario uses a private server/store and all Odin allocations are tracked.
@(test)
test_jetstream_real_server :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_publish_and_rollup(t)
	test_durable_delivery(t)
	test_persisted_ack_and_advisory(t)
	test_notification_snapshots(t)
	test_errors_and_outage(t)
	test_tls(t)
	err := shutdown(5000)
	testing.expectf(t, err.status == 0, "shutdown: %s", error_text(err))
	testing.expectf(t, len(track.allocation_map) == 0, "Odin live allocations: %d", len(track.allocation_map))
}

test_connect :: proc(t: ^testing.T, url: string) -> ^Connection {
	conn, err := connect({url = url, timeout_ms = 500})
	testing.expectf(t, err.status == 0, "connect: %s", error_text(err))
	return conn
}

make_subjects :: proc() -> []string {
	result := make([]string, 1, context.temp_allocator)
	result[0] = "ev.>"
	return result
}

test_stream :: proc() -> Stream_Config {
	return {
		name = "EVENTS",
		subjects = (make_subjects()),
		max_age_ns = i64(24 * time.Hour),
		duplicate_window_ns = i64(2 * time.Minute),
		replicas = 1,
		allow_rollup = true,
	}
}

test_publish_and_rollup :: proc(t: ^testing.T) {
	srv, ok := server.start()
	defer server.destroy(&srv)
	if !testing.expect(t, ok, "real nats-server starts") do return
	conn := test_connect(t, srv.url)
	if conn == nil do return
	defer destroy(conn)
	cfg := test_stream()
	_, err := stream_add(conn, cfg)
	if !testing.expectf(t, err.status == 0, "stream add: %v %s", err, error_text(err)) do return
	_, err = stream_update(conn, cfg)
	testing.expectf(t, err.status == 0, "stream update: %v", err)
	a: Pub_Ack
	a, err = publish(conn, "ev.task.occurrence", test_bytes("one"), "event-1", []Header{{"X-Test", "hello"}})
	if !testing.expectf(t, err.status == 0, "publish: %v", err) do return
	duplicate: Pub_Ack
	duplicate, err = publish(conn, "ev.task.occurrence", test_bytes("two"), "event-1")
	testing.expect(
		t,
		err.status == 0 && duplicate.duplicate != 0 && duplicate.sequence == a.sequence,
		"msg-id dedupes",
	)
	state: Stream_State
	state, err = stream_info(conn, cfg.name)
	testing.expect(t, err.status == 0 && state.messages == 1, "one deduped stored message")
	_, err = publish(conn, "ev.task.state", test_bytes("old"), "state-1")
	testing.expect(t, err.status == 0)
	latest: Pub_Ack
	latest, err = publish(conn, "ev.task.state", test_bytes("new"), "state-2", []Header{{"Nats-Rollup", "sub"}})
	testing.expect(t, err.status == 0)
	state, err = stream_info(conn, cfg.name)
	testing.expectf(t, err.status == 0 && state.messages == 2, "rollup keeps occurrence and latest state: %v", state)
	err = consumer_add(
		conn,
		{
			stream = cfg.name,
			durable = "read",
			filter_subjects = []string{"ev.>"},
			ack_wait_ns = i64(time.Second),
			max_deliver = 10,
		},
	)
	if !testing.expectf(t, err.status == 0, "consumer: %v", err) do return
	pull: ^Pull
	pull, err = pull_bind(conn, cfg.name, "read")
	if !testing.expectf(t, err.status == 0, "bind: %v", err) do return
	defer pull_destroy(pull)
	batch: ^Batch
	batch, err = fetch(pull, 10, 1000)
	if !testing.expectf(t, err.status == 0, "fetch: %v", err) do return
	defer batch_destroy(batch)
	testing.expect(t, batch_count(batch) == 2)
	first := batch_message(batch, 0)
	value: string
	value, err = message_header(first, "X-Test")
	testing.expect(t, err.status == 0 && value == "hello")
	id: string
	id, err = message_header(first, "Nats-Msg-Id")
	testing.expect(t, err.status == 0 && id == "event-1")
	_, err = message_header(first, "Missing")
	testing.expect(t, err.status != 0)
	last := batch_message(batch, 1)
	testing.expect(t, string(message_data(last)) == "new" && message_subject(last) == "ev.task.state")
	meta: Metadata
	meta, err = message_metadata(last)
	testing.expect(t, err.status == 0 && meta.stream_sequence == latest.sequence && meta.num_delivered == 1)
	testing.expect(t, ack(first).status == 0 && ack(last).status == 0)
	testing.expect(t, batch_message(batch, -1) == nil && batch_message(batch, 2) == nil)
}

test_durable_delivery :: proc(t: ^testing.T) {
	srv, ok := server.start()
	defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	conn := test_connect(t, srv.url)
	if conn == nil do return
	defer destroy(conn)
	cfg := test_stream()
	_, err := stream_add(conn, cfg)
	if !testing.expect(t, err.status == 0) do return
	err = consumer_add(
		conn,
		{
			stream = cfg.name,
			durable = "worker",
			filter_subjects = []string{"ev.work", "ev.other"},
			ack_wait_ns = i64(150 * time.Millisecond),
			max_deliver = 10,
		},
	)
	if !testing.expectf(t, err.status == 0, "multi-filter consumer: %v", err) do return
	_, err = publish(conn, "ev.work", test_bytes("work"), "work-1")
	testing.expect(t, err.status == 0)
	pull: ^Pull
	pull, err = pull_bind(conn, cfg.name, "worker")
	if !testing.expect(t, err.status == 0) do return
	batch: ^Batch
	batch, err = fetch(pull, 1, 1000)
	if !testing.expect(t, err.status == 0) {pull_destroy(pull); return}
	msg := batch_message(batch, 0)
	m1: Metadata
	m1, err = message_metadata(msg)
	testing.expect(t, err.status == 0 && m1.num_delivered == 1)
	testing.expect(t, nak(msg).status == 0)
	batch_destroy(batch)
	// Closing a local pull must preserve the existing durable consumer.
	pull_destroy(pull)
	pull, err = pull_bind(conn, cfg.name, "worker")
	if !testing.expectf(t, err.status == 0, "rebind durable: %v", err) do return
	defer pull_destroy(pull)
	batch, err = fetch(pull, 1, 1000)
	if !testing.expectf(t, err.status == 0, "nak redelivery: %v", err) do return
	msg = batch_message(batch, 0)
	m2: Metadata
	m2, err = message_metadata(msg)
	testing.expect(t, err.status == 0 && m2.stream_sequence == m1.stream_sequence && m2.num_delivered >= 2)
	// Leave it unacked; ack_wait must redeliver, independently of nak.
	batch_destroy(batch)
	time.sleep(180 * time.Millisecond)
	batch, err = fetch(pull, 1, 1000)
	if !testing.expect(t, err.status == 0) do return
	msg = batch_message(batch, 0)
	m3: Metadata
	m3, err = message_metadata(msg)
	testing.expect(t, err.status == 0 && m3.num_delivered > m2.num_delivered)
	testing.expect(t, ack(msg).status == 0)
	batch_destroy(batch)
	batch, err = fetch(pull, 1, 100)
	testing.expect(t, err.status != 0 && batch == nil, "acked message not redelivered")
	batch_destroy(batch)
	_, err = publish(conn, "ev.other", test_bytes("term"), "work-2")
	testing.expect(t, err.status == 0)
	batch, err = fetch(pull, 1, 1000)
	if !testing.expect(t, err.status == 0) do return
	testing.expect(t, term(batch_message(batch, 0)).status == 0)
	batch_destroy(batch)
	time.sleep(180 * time.Millisecond)
	batch, err = fetch(pull, 1, 100)
	testing.expect(t, err.status != 0 && batch == nil, "term suppresses redelivery")
	batch_destroy(batch)
	testing.expect(t, consumer_delete(conn, cfg.name, "worker").status == 0)
	testing.expect(t, consumer_delete(conn, cfg.name, "worker").status != 0)
}

test_errors_and_outage :: proc(t: ^testing.T) {
	srv, ok := server.start()
	defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	conn := test_connect(t, srv.url)
	if conn == nil do return
	defer destroy(conn)
	cfg := test_stream()
	_, err := stream_info(conn, "MISSING")
	testing.expect(t, err.status != 0)
	_, err = stream_update(conn, cfg)
	testing.expect(t, err.status != 0)
	_, err = stream_add(conn, cfg)
	testing.expect(t, err.status == 0)
	// Invalid server configs exercise returned-info cleanup on C error paths.
	bad := cfg
	bad.name = "bad.name"
	_, err = stream_add(conn, bad)
	testing.expect(t, err.status != 0)
	err = consumer_add(conn, {stream = "MISSING", durable = "x", ack_wait_ns = i64(time.Second), max_deliver = 10})
	testing.expect(t, err.status != 0)
	missing, bind_err := pull_bind(conn, cfg.name, "MISSING")
	testing.expect(t, bind_err.status != 0 && missing == nil)
	pull_destroy(missing)
	_, err = publish(conn, "outside.stream", test_bytes("error"), "missing")
	testing.expect(t, err.status != 0, "publish message cleaned on no stream")
	err = consumer_add(conn, {stream = cfg.name, durable = "read", ack_wait_ns = i64(time.Second), max_deliver = 10})
	if !testing.expect(t, err.status == 0) do return
	pull: ^Pull
	pull, err = pull_bind(conn, cfg.name, "read")
	if !testing.expect(t, err.status == 0) do return
	defer pull_destroy(pull)
	// Option failures free natsOptions and any partial handle.
	invalid, invalid_err := connect({url = srv.url, creds_file = "/no/such/creds", timeout_ms = 200})
	testing.expect(t, invalid_err.status != 0 && invalid == nil)
	destroy(invalid)
	invalid, invalid_err = connect({url = srv.url, ca_file = "/no/such/ca", timeout_ms = 200})
	testing.expect(t, invalid_err.status != 0 && invalid == nil)
	destroy(invalid)
	server.stop(&srv)
	_, err = publish(conn, "ev.task.state", test_bytes("outage"), "down")
	testing.expect(t, err.status != 0, "publish fails safely while down")
	batch: ^Batch
	batch, err = fetch(pull, 1, 100)
	testing.expect(t, err.status != 0 && batch == nil, "fetch fails safely while down")
	batch_destroy(batch)
	_, err = stream_info(conn, cfg.name)
	testing.expect(t, err.status != 0)
	invalid, invalid_err = connect({url = srv.url, timeout_ms = 100})
	testing.expect(t, invalid_err.status != 0 && invalid == nil, "connect fails safely while down")
	destroy(invalid)
	// Reject embedded NULs rather than silently truncating credentials/subjects.
	_, err = publish(conn, "ev.\x00bad", nil)
	testing.expect(t, err.status != 0)
	testing.expect(t, batch_count(nil) == 0 && batch_message(nil, 0) == nil)
	testing.expect(t, ack(nil).status != 0 && nak(nil).status != 0 && term(nil).status != 0)
}

test_bytes :: proc(s: string) -> []byte {return transmute([]byte)s}

// Real TLS handshakes cover CA loading, trust rejection and success. The server
// uses an ephemeral self-signed CA, never a host/global trust-store mutation.
test_tls :: proc(t: ^testing.T) {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, terr == nil) do return
	dir := fmt.tprintf("%s/heimdall-nats-tls-%d-%d", tmp, os.get_pid(), time.tick_now())
	if !testing.expect(t, os.make_directory(dir) == nil) do return
	defer _ = os.remove_all(dir)
	key := fmt.tprintf("%s/key.pem", dir)
	cert := fmt.tprintf("%s/cert.pem", dir)
	child, perr := os.process_start(
		os.Process_Desc {
			command = []string {
				"openssl",
				"req",
				"-x509",
				"-newkey",
				"rsa:2048",
				"-nodes",
				"-keyout",
				key,
				"-out",
				cert,
				"-days",
				"1",
				"-subj",
				"/CN=localhost",
				"-addext",
				"subjectAltName=DNS:localhost,IP:127.0.0.1",
			},
		},
	)
	if !testing.expect(t, perr == nil) do return
	state, werr := os.process_wait(child)
	if !testing.expect(t, werr == nil && state.exit_code == 0) do return
	srv, ok := server.start([]string{"--tls", "--tlscert", cert, "--tlskey", key})
	defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	// No CA => handshake must not trust this certificate.
	untrusted, err := connect({url = srv.url, timeout_ms = 1000})
	testing.expect(t, err.status != 0 && untrusted == nil)
	destroy(untrusted)
	trusted, trusted_err := connect({url = srv.url, ca_file = cert, timeout_ms = 1000})
	if !testing.expectf(t, trusted_err.status == 0, "trusted TLS: %v %s", trusted_err, error_text(trusted_err)) do return
	defer destroy(trusted)
	_, stream_err := stream_add(trusted, test_stream())
	testing.expectf(t, stream_err.status == 0, "TLS JetStream request: %v", stream_err)
}

// The HTTP request destroys its batch before a later ack request. Exercise that
// lifetime as well as the exact max-delivery advisory/raw-message path.
test_persisted_ack_and_advisory :: proc(t: ^testing.T) {
	srv, ok := server.start()
	defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	conn := test_connect(t, srv.url)
	if conn == nil do return
	defer destroy(conn)
	_, err := stream_add(conn, test_stream())
	if !testing.expect_value(t, err.status, i32(0)) do return

	_, aerr := stream_add(
		conn,
		{
			name = "ADVISORIES",
			subjects = []string{"$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.EVENTS.>"},
			max_age_ns = i64(time.Minute),
			replicas = 1,
		},
	)
	if !testing.expect_value(t, aerr.status, i32(0)) do return
	aerr = consumer_add(
		conn,
		{stream = "ADVISORIES", durable = "advisories", ack_wait_ns = i64(time.Second), max_deliver = 10},
	)
	if !testing.expect_value(t, aerr.status, i32(0)) do return
	advisory, bind_advisory_err := pull_bind(conn, "ADVISORIES", "advisories")
	if !testing.expect_value(t, bind_advisory_err.status, i32(0)) do return
	defer pull_destroy(advisory)
	err = consumer_add(
		conn,
		{
			stream = "EVENTS",
			durable = "persist",
			filter_subjects = []string{"ev.work"},
			ack_wait_ns = i64(40 * time.Millisecond),
			max_deliver = 2,
		},
	)
	if !testing.expect_value(t, err.status, i32(0)) do return
	pull, perr := pull_bind(conn, "EVENTS", "persist")
	if !testing.expect_value(t, perr.status, i32(0)) do return
	defer pull_destroy(pull)
	_, err = publish(conn, "ev.work", test_bytes("acked"), "persist-1")
	testing.expect_value(t, err.status, i32(0))
	batch, berr := fetch(pull, 1, 500)
	if !testing.expect_value(t, berr.status, i32(0)) do return
	reply := strings.clone(message_reply(batch_message(batch, 0)))
	defer delete(reply)
	batch_destroy(batch)
	testing.expect_value(t, ack_reply(conn, reply, 500).status, i32(0))
	batch, berr = fetch(pull, 1, 50)
	testing.expect(t, berr.status != 0 && batch == nil, "persisted reply ack suppresses redelivery")
	batch_destroy(batch)
	published, puberr := publish(conn, "ev.work", test_bytes("poison"), "persist-2")
	testing.expect_value(t, puberr.status, i32(0))
	for _ in 0 ..< 2 {
		batch, berr = fetch(pull, 1, 500)
		if !testing.expect_value(t, berr.status, i32(0)) do return
		batch_destroy(batch)
		time.sleep(60 * time.Millisecond)
	}
	// A fetch after the final ack_wait causes JetStream to report exhaustion.
	batch, berr = fetch(pull, 1, 100)
	testing.expect(t, berr.status != 0 && batch == nil)
	batch_destroy(batch)

	notices, nerr := fetch(advisory, 1, 500)
	if !testing.expect_value(t, nerr.status, i32(0)) do return
	defer batch_destroy(notices)
	notice := batch_message(notices, 0)
	testing.expect(t, strings.contains(string(message_data(notice)), "max_deliver"))
	testing.expect_value(t, ack(notice).status, i32(0))
	stored, serr := stream_get(conn, "EVENTS", published.sequence)
	if !testing.expect_value(t, serr.status, i32(0)) do return
	defer message_destroy(stored)
	testing.expect_value(t, string(message_data(stored)), "poison")
	testing.expect_value(t, message_subject(stored), "ev.work")
	missing, merr := stream_get(conn, "MISSING", 1)
	testing.expect(t, merr.status != 0 && missing == nil)
	message_destroy(missing)
	empty, eerr := fetch(advisory, 1, 10)
	testing.expect(t, eerr.status != 0 && empty == nil)
	batch_destroy(empty)
}

test_notification_snapshots :: proc(t: ^testing.T) {
	srv, ok := server.start()
	defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	conn := test_connect(t, srv.url)
	if conn == nil do return
	defer destroy(conn)
	cfg := test_stream()
	cfg.allow_direct = true
	_, err := stream_add(conn, cfg)
	if !testing.expect_value(t, err.status, i32(0)) do return
	a, _ := publish(conn, "ev.match", test_bytes("one"), "notice-1")
	_, _ = publish(conn, "ev.other", test_bytes("skip"), "notice-2")
	b, _ := publish(conn, "ev.match", test_bytes("two"), "notice-3")
	err = consumer_add(
		conn,
		{
			stream = cfg.name,
			durable = "observe",
			filter_subjects = []string{"ev.match"},
			ack_wait_ns = i64(time.Minute),
			max_deliver = 10,
		},
	)
	if !testing.expect_value(t, err.status, i32(0)) do return
	for expected, i in ([2]u64{a.sequence, b.sequence}) {
		msg, sequence, read_err := stream_next(conn, cfg.name, "ev.match", 1 if i == 0 else a.sequence + 1)
		if testing.expect_value(t, read_err.status, i32(0)) do testing.expect_value(t, sequence, expected)
		message_destroy(msg)
	}
	missing, _, missing_err := stream_next(conn, cfg.name, "ev.match", b.sequence + 1)
	testing.expect(t, missing == nil && missing_err.status == 13)
	message_destroy(missing)
	snapshot, snapshot_err := consumer_state(conn, cfg.name, "observe")
	testing.expect_value(t, snapshot_err.status, i32(0))
	testing.expect_value(t, snapshot.pending, u64(2))
	testing.expect_value(t, snapshot.delivered, u64(0))
	testing.expect_value(t, snapshot.ack_pending, u64(0))
	_, snapshot_err = consumer_state(conn, cfg.name, "missing")
	testing.expect(t, snapshot_err.status != 0)
	missing, _, missing_err = stream_next(conn, "MISSING", "ev.match", 1)
	testing.expect(t, missing == nil && missing_err.status != 0)
	message_destroy(missing)
	_, invalid := consumer_state(nil, cfg.name, "observe")
	testing.expect_value(t, invalid.status, INVALID)
	missing, _, invalid = stream_next(nil, cfg.name, "ev.match", 1)
	testing.expect_value(t, invalid.status, INVALID)
	message_destroy(missing)
}
