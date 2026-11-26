package nats

import server "../natstest"
import "core:fmt"
import "core:encoding/json"
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
	scenario_exact_start_time(t)
	test_publish_and_rollup(t)
	test_durable_delivery(t)
	test_persisted_ack_and_advisory(t)
	test_notification_snapshots(t)
	test_errors_and_outage(t)
	test_tls(t)
	scenario_schedule_every(t)
	scenario_schedule_cron_time_zone(t)
	scenario_schedule_at_past(t)
	scenario_ttl_never_outlives_max_age(t)
	scenario_purge_subject(t)
	scenario_purge_count(t)
	scenario_stream_update_keeps_data(t)
	scenario_deliver_new(t)
	scenario_metadata_timestamp(t)
	scenario_supports_schedules(t)
	scenario_work_queue_ack_removes(t)
	scenario_work_queue_disjoint_consumers(t)
	scenario_max_ack_pending(t)
	scenario_nak_reply_delay(t)
	scenario_in_progress_reply(t)
	scenario_term_reply(t)
	scenario_ack_reply_work_queue(t)
	scenario_max_deliver_advisory(t)
	scenario_delayed_nak_counts_toward_max_ack_pending(t)
	scenario_ack_reply_async(t)
	scenario_delete_message(t)
	scenario_schedule_fire_ttl(t)
    scenario_long_pull_local_timeouts(t)
	err := shutdown(5000)
	testing.expectf(t, err.status == 0, "shutdown: %s", error_text(err))
	testing.expectf(t, len(track.allocation_map) == 0, "Odin live allocations: %d", len(track.allocation_map))
}

// Parse the server's UTC nanoseconds as decimal digits. The generic time parser
// in the pinned Odin toolchain truncates fractions, so it is not an oracle here.
test_exact_utc_ns :: proc(t: ^testing.T, value: string) -> i64 {
	if !testing.expect(t, len(value) >= 20 && value[len(value)-1] == 'Z', value) do return -1
	base, consumed := time.rfc3339_to_time_utc(fmt.tprintf("%sZ", value[:19]))
	if !testing.expect_value(t, consumed, 20) do return -1
	fraction: i64
	digits := 0
	if len(value) > 20 {
		if !testing.expect(t, value[19] == '.' && len(value) <= 30, value) do return -1
		for ch in value[20:len(value)-1] {
			if !testing.expect(t, ch >= '0' && ch <= '9', value) do return -1
			fraction = fraction * 10 + i64(ch - '0')
			digits += 1
		}
		if !testing.expect(t, digits > 0 && digits <= 9, value) do return -1
	}
	for digits < 9 {fraction *= 10; digits += 1}
	return time.to_unix_nanoseconds(base) + fraction
}

test_time_consumer :: proc(t: ^testing.T, conn: ^Connection, name: string, cutoff: i64) -> bool {
	err := consumer_add(conn, {
		stream = "TIMES", durable = name, filter_subjects = []string{"ev.target"},
		ack_wait_ns = i64(time.Minute), max_deliver = 1, start_time_ns = cutoff,
	})
	if !testing.expectf(t, err.status == 0, "time consumer %s: %v", name, err) do return false
	api := strings.clone_to_cstring(fmt.tprintf("$JS.API.CONSUMER.INFO.TIMES.%s", name))
	defer delete(api)
	msg: ^Message
	status := ham_nats_request(&msg, conn, api, nil, 0)
	if !testing.expect_value(t, status, i32(0)) do return false
	defer message_destroy(msg)
	info: struct {
		config: struct {
			opt_start_time, deliver_policy, ack_policy, replay_policy, filter_subject: string,
			ack_wait, max_deliver: i64,
		},
		error: struct {code: i32},
	}
	decode_err := json.unmarshal(message_data(msg), &info)
	defer delete(info.config.opt_start_time)
	defer delete(info.config.deliver_policy)
	defer delete(info.config.ack_policy)
	defer delete(info.config.replay_policy)
	defer delete(info.config.filter_subject)
	if !testing.expectf(t, decode_err == nil && info.error.code == 0, "consumer info: %s", message_data(msg)) do return false
	testing.expect(t, info.config.deliver_policy == "by_start_time" &&
		info.config.ack_policy == "explicit" && info.config.replay_policy == "instant" &&
		info.config.filter_subject == "ev.target" && info.config.ack_wait == i64(time.Minute) &&
		info.config.max_deliver == 1, "preserve filter, delivery, ack and replay settings")
	return testing.expectf(t, test_exact_utc_ns(t, info.config.opt_start_time) == cutoff,
		"server cutoff %s: intended %d got %s", name, cutoff, info.config.opt_start_time)
}

scenario_exact_start_time :: proc(t: ^testing.T) {
	// Literal expectations exercise the actual linked nats.c encoder, rather than
	// reproducing its formatter in a mock. Include 1-9 digit leading-zero scales.
	cases := []struct {fraction: i64, suffix: string}{
		{0, "Z"}, {1, ".000000001Z"}, {10, ".00000001Z"},
		{100, ".0000001Z"}, {1000, ".000001Z"}, {10000, ".00001Z"},
		{100000, ".0001Z"}, {1000000, ".001Z"}, {7181125, ".007181125Z"},
		{10000000, ".01Z"}, {60000000, ".06Z"}, {62000000, ".062Z"},
		{80000000, ".08Z"}, {81000000, ".081Z"}, {90000000, ".09Z"},
		{100000000, ".1Z"}, {990000000, ".99Z"}, {999999999, ".999999999Z"},
	}
	for item in cases {
		ns := i64(1700000000000000000) + item.fraction
		buf: [64]u8
		status := nats_EncodeTimeUTC(raw_data(buf[:]), len(buf), ns)
		if !testing.expect_value(t, status, i32(0)) do return
		encoded := string(cstring(raw_data(buf[:])))
		testing.expect_value(t, encoded, fmt.tprintf("2023-11-14T22:13:20%s", item.suffix))
		testing.expect_value(t, test_exact_utc_ns(t, encoded), ns)
	}
	srv, ok := server.start()
	defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	conn := test_connect(t, srv.url)
	if conn == nil do return
	defer destroy(conn)
	_, err := stream_add(conn, {name = "TIMES", subjects = []string{"ev.>"}, replicas = 1})
	if !testing.expect_value(t, err.status, i32(0)) do return
	target, pub_err := publish(conn, "ev.target", test_bytes("target"), "target")
	if !testing.expect_value(t, pub_err.status, i32(0)) do return
	_, err = publish(conn, "ev.other", test_bytes("filtered"), "filtered")
	if !testing.expect_value(t, err.status, i32(0)) do return
	// Read authoritative stored metadata once. No clock polling, sleeps, retries
	// or assumptions about which fractional second publication happens in.
	err = consumer_add(conn, {stream = "TIMES", durable = "metadata",
		filter_subjects = []string{"ev.target"}, ack_wait_ns = i64(time.Minute), max_deliver = 1})
	if !testing.expect_value(t, err.status, i32(0)) do return
	pull, bind_err := pull_bind(conn, "TIMES", "metadata")
	if !testing.expect_value(t, bind_err.status, i32(0)) do return
	defer pull_destroy(pull)
	batch, fetch_err := fetch(pull, 1, 1000)
	if !testing.expect(t, fetch_err.status == 0 && batch_count(batch) == 1) do return
	defer batch_destroy(batch)
	meta, meta_err := message_metadata(batch_message(batch, 0))
	if !testing.expect(t, meta_err.status == 0 && meta.stream_sequence == target.sequence && meta.timestamp_ns > 0) do return
	if !testing.expect_value(t, ack(batch_message(batch, 0)).status, i32(0)) do return
	// All fixed fractions are in a past second derived from the stored message.
	// Each server response must retain the exact intended cutoff through nats.c.
	base := meta.timestamp_ns - meta.timestamp_ns % 1000000000 - 2 * 1000000000
	for item, i in cases {
		name := fmt.tprintf("fraction-%d", i)
		if !test_time_consumer(t, conn, name, base + item.fraction) do return
		testing.expect_value(t, consumer_delete(conn, "TIMES", name).status, i32(0))
	}
	// Same filter/ack/replay settings and target on both sides of the boundary:
	// inclusive at the exact stored nanosecond, excluded one nanosecond later.
	for cutoff, i in ([]i64{meta.timestamp_ns, meta.timestamp_ns + 1}) {
		name := fmt.tprintf("boundary-%d", i)
		if !test_time_consumer(t, conn, name, cutoff) do return
		defer consumer_delete(conn, "TIMES", name)
		state, state_err := consumer_state(conn, "TIMES", name)
		if !testing.expect_value(t, state_err.status, i32(0)) do return
		testing.expect_value(t, state.pending, u64(1 - i))
		p, e := pull_bind(conn, "TIMES", name)
		if !testing.expect_value(t, e.status, i32(0)) do return
		defer pull_destroy(p)
		b, fe := fetch_available(p, 2)
		defer batch_destroy(b)
		if i == 0 {
			if !testing.expect(t, fe.status == 0 && batch_count(b) == 1, "eligible target delivered exactly once") do return
			msg := batch_message(b, 0)
			m, me := message_metadata(msg)
			testing.expect(t, me.status == 0 && m.stream_sequence == target.sequence && m.timestamp_ns == meta.timestamp_ns)
			testing.expect_value(t, string(message_data(msg)), "target")
			testing.expect_value(t, ack(msg).status, i32(0))
		} else {
			testing.expect(t, fe.status == 26 && batch_count(b) == 0, "pre-boundary target excluded")
		}
	}
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
	redelivery_started := time.tick_now()
	batch, err = fetch(pull, 1, 1000)
	redelivery_elapsed_ns := i64(time.tick_since(redelivery_started))
	if !testing.expectf(t, err.status == 0,
		"ack-wait redelivery: status=%d jetstream=%d error=%s elapsed_ns=%d",
		err.status, err.jetstream, error_text(err), redelivery_elapsed_ns) {
		return
	}
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

@(test)
test_version_at_least :: proc(t: ^testing.T) {
	for v in ([]string{"2.14.0", "2.14.7", "3.0.0", "2.14.0-RC.1"}) do testing.expect(t, version_at_least(v, 2, 14, 0), v)
	for v in ([]string{"2.13.9", "2.12.3", "", "abc", "2.14", "2..14", "2.14.0.1", "2.14.x", "9999999999999999999999.0.0"}) do testing.expect(t, !version_at_least(v, 2, 14, 0), v)
}
@(test)
test_subject_token :: proc(t: ^testing.T) {
	testing.expect(t, subject_token("usr_1"))
	for v in ([]string{"", "a.b", "a*", "a>", "a b", "a\tb", "a\x00", "a\x7f"}) do testing.expect(t, !subject_token(v), v)
}
Feature_Fixture :: struct {srv: server.Server, conn: ^Connection, pull: ^Pull}
feature_start :: proc(t: ^testing.T, work_queue := false, max_age := time.Hour, max_pending: i64 = 0, ack_wait := 10 * time.Second, max_deliver: i64 = 10, deliver_new := false) -> (f: Feature_Fixture) {
	ok: bool
	f.srv, ok = server.start()
	if !testing.expect(t, ok) do return
	f.conn = test_connect(t, f.srv.url)
	if f.conn == nil do return
	cfg := Stream_Config{name = "FEATURE", subjects = []string{"ev.>", "sched.def.>", "dlv.>"},
		max_age_ns = i64(max_age), replicas = 1, allow_direct = true,
		allow_msg_schedules = !work_queue, allow_msg_ttl = !work_queue,
		retention = .Work_Queue if work_queue else .Limits}
	_, err := stream_add(f.conn, cfg)
	if !testing.expectf(t, err.status == 0, "feature stream: %v", err) do return
	err = consumer_add(f.conn, {stream = "FEATURE", durable = "read", filter_subjects = []string{"ev.>"},
		ack_wait_ns = i64(ack_wait), max_deliver = max_deliver, max_ack_pending = max_pending, deliver_new = deliver_new})
	if !testing.expectf(t, err.status == 0, "feature consumer: %v", err) do return
	f.pull, err = pull_bind(f.conn, "FEATURE", "read")
	testing.expect_value(t, err.status, i32(0))
	return
}
feature_destroy :: proc(f: ^Feature_Fixture) {
	pull_destroy(f.pull); destroy(f.conn); server.destroy(&f.srv)
}
feature_publish :: proc(t: ^testing.T, f: ^Feature_Fixture, subject: string, headers: []Header = nil) -> Pub_Ack {
	started := time.tick_now()
	a, err := publish(f.conn, subject, test_bytes("payload"), "", headers)
	elapsed_ns := i64(time.tick_since(started))
	pattern := ""
	if err.status != 0 {
		for header in headers {
			if header.key == "Nats-Schedule" {pattern = header.value; break}
		}
	}
	testing.expectf(t, err.status == 0,
		"feature publish %s schedule=%q: status=%d jetstream=%d error=%s elapsed_ns=%d",
		subject, pattern, err.status, err.jetstream, error_text(err), elapsed_ns)
	return a
}
feature_schedule :: proc(t: ^testing.T, f: ^Feature_Fixture, pattern: string, extra: []Header = nil) {
	h := make([dynamic]Header); defer delete(h)
	append(&h, Header{"Nats-Schedule", pattern}, Header{"Nats-Schedule-Target", "ev.fire"},
		Header{"Nats-TTL", "never"}, Header{"X-Custom", "kept"})
	append(&h, ..extra)
	feature_publish(t, f, "sched.def.test", h[:])
}
feature_count :: proc(t: ^testing.T, f: ^Feature_Fixture, subject: string, expected: u64) {
	n, err := subject_count(f.conn, "FEATURE", subject)
	testing.expectf(t, err.status == 0 && n == expected, "count %s expected %d got %d: %v", subject, expected, n, err)
}
feature_fetch :: proc(t: ^testing.T, f: ^Feature_Fixture, count: int, wait: i64 = 1000) -> ^Batch {
	b, err := fetch(f.pull, count, wait)
	testing.expectf(t, err.status == 0 || err.status == 26 || err.status == 29, "fetch: %v", err)
	return b
}
scenario_schedule_every :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	feature_schedule(t, &f, "@every 1s")
	started := time.tick_now()
	fired := 0
	for fired < 2 && time.tick_since(started) < 4 * time.Second {
		b := feature_fetch(t, &f, 1); defer batch_destroy(b)
		if batch_count(b) == 0 do continue
		m := batch_message(b, 0)
		next, err := message_header(m, "Nats-Schedule-Next")
		testing.expect(t, err.status == 0 && next != "")
		custom, _ := message_header(m, "X-Custom"); testing.expect_value(t, custom, "kept")
		testing.expect_value(t, ack(m).status, i32(0))
		fired += 1
	}
	testing.expect(t, fired >= 2 && time.tick_since(started) < 4 * time.Second)
}
scenario_schedule_cron_time_zone :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	feature_schedule(t, &f, "* * * * * *", []Header{{"Nats-Schedule-Time-Zone", "Asia/Kolkata"}})
	b := feature_fetch(t, &f, 1, 2500); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	v, err := message_header(batch_message(b, 0), "Nats-Schedule-Next")
	testing.expectf(t, err.status == 0 && strings.has_suffix(v, "+05:30"), "next %s: %v", v, err)
}
scenario_schedule_at_past :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	feature_schedule(t, &f, "@at 2020-01-01T00:00:00Z")
	b := feature_fetch(t, &f, 1, 2000); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	v, err := message_header(batch_message(b, 0), "Nats-Schedule-Next")
	testing.expect(t, err.status == 0 && v == "purge")
	testing.expect_value(t, ack(batch_message(b, 0)).status, i32(0))
	feature_count(t, &f, "sched.def.test", 0)
	b2 := feature_fetch(t, &f, 1, 300); defer batch_destroy(b2)
	testing.expect_value(t, batch_count(b2), 0)
}
scenario_ttl_never_outlives_max_age :: proc(t: ^testing.T) {
	f := feature_start(t, max_age = 2 * time.Second); defer feature_destroy(&f)
	feature_schedule(t, &f, "@every 1h")
	feature_publish(t, &f, "ev.plain")
	time.sleep(4 * time.Second)
	feature_count(t, &f, "sched.def.test", 1); feature_count(t, &f, "ev.plain", 0)
}
scenario_purge_subject :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	feature_schedule(t, &f, "@every 1s")
	n, err := stream_purge_subject(f.conn, "FEATURE", "sched.def.test")
	testing.expect(t, err.status == 0 && n == 1)
	b := feature_fetch(t, &f, 1, 3000); defer batch_destroy(b)
	testing.expect_value(t, batch_count(b), 0)
	n, err = stream_purge_subject(f.conn, "FEATURE", "sched.def.test")
	testing.expect(t, err.status == 0 && n == 0)
}
scenario_purge_count :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	for _ in 0 ..< 7 do feature_publish(t, &f, "ev.purge")
	feature_publish(t, &f, "ev.keep")
	n, err := stream_purge_subject(f.conn, "FEATURE", "ev.purge")
	testing.expectf(t, err.status == 0 && n == 7, "exact server count %d: %v", n, err)
	feature_count(t, &f, "ev.keep", 1)
	_, err = stream_purge_subject(f.conn, "FEATURE", "ev.*"); testing.expect_value(t, err.status, INVALID)
	_, err = stream_purge_subject(f.conn, "MISSING", "ev.purge"); testing.expect(t, err.status != 0 && err.jetstream != 0)
}
scenario_stream_update_keeps_data :: proc(t: ^testing.T) {
	srv, ok := server.start(); defer server.destroy(&srv)
	if !testing.expect(t, ok) do return
	conn := test_connect(t, srv.url); defer destroy(conn)
	cfg := test_stream()
	_, err := stream_add(conn, cfg); testing.expect_value(t, err.status, i32(0))
	for i in 0 ..< 3 { _, e := publish(conn, "ev.old", test_bytes("old")); testing.expect_value(t, e.status, i32(0)) }
	testing.expect_value(t, consumer_add(conn, {stream = cfg.name, durable = "old", filter_subjects = []string{"ev.>"}, ack_wait_ns = i64(time.Second), max_deliver = 3}).status, i32(0))
	cfg.subjects = []string{"ev.>", "sched.def.>"}; cfg.allow_msg_schedules = true; cfg.allow_msg_ttl = true
	state, e := stream_update(conn, cfg); testing.expect(t, e.status == 0 && state.messages == 3)
	_, e = consumer_state(conn, cfg.name, "old"); testing.expect_value(t, e.status, i32(0))
}
scenario_deliver_new :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	for _ in 0 ..< 2 do feature_publish(t, &f, "ev.old")
	e := consumer_add(f.conn, {stream = "FEATURE", durable = "new", filter_subjects = []string{"ev.>"}, ack_wait_ns = i64(time.Second), max_deliver = 3, deliver_new = true})
	testing.expect_value(t, e.status, i32(0))
	p, err := pull_bind(f.conn, "FEATURE", "new"); defer pull_destroy(p); testing.expect_value(t, err.status, i32(0))
	b, _ := fetch_available(p, 10); testing.expect_value(t, batch_count(b), 0); batch_destroy(b)
	a := feature_publish(t, &f, "ev.new")
	b, err = fetch(p, 10, 500); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	meta, me := message_metadata(batch_message(b, 0)); testing.expect(t, me.status == 0 && meta.stream_sequence == a.sequence)
}
scenario_metadata_timestamp :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	feature_publish(t, &f, "ev.timestamp")
	b := feature_fetch(t, &f, 1); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	meta, err := message_metadata(batch_message(b, 0))
	delta := time.to_unix_nanoseconds(time.now()) - meta.timestamp_ns
	testing.expectf(t, err.status == 0 && delta >= 0 && delta < i64(5 * time.Second), "metadata timestamp: %v %d", meta, delta)
}
scenario_supports_schedules :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)
	ok, err := server_supports_schedules(f.conn, "FEATURE")
	testing.expectf(t, ok && err.status == 0, "schedule support: %v %v", ok, err)
	ok, err = server_supports_schedules(f.conn, "MISSING"); testing.expect(t, !ok && err.status != 0)
}
scenario_work_queue_ack_removes :: proc(t: ^testing.T) {
	f := feature_start(t, true); defer feature_destroy(&f)
	feature_publish(t, &f, "ev.work")
	b := feature_fetch(t, &f, 1); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	testing.expect_value(t, ack(batch_message(b, 0)).status, i32(0))
	feature_count(t, &f, "ev.work", 0)
}
scenario_work_queue_disjoint_consumers :: proc(t: ^testing.T) {
	f := feature_start(t, true); defer feature_destroy(&f)
	for id in ([]string{"b1", "b2"}) {
		err := consumer_add(f.conn, {stream = "FEATURE", durable = id, filter_subjects = []string{fmt.tprintf("dlv.*.%s.>", id)}, ack_wait_ns = i64(time.Second), max_deliver = 3})
		testing.expect_value(t, err.status, i32(0))
	}
	e := consumer_add(f.conn, {stream = "FEATURE", durable = "overlap", filter_subjects = []string{"dlv.>"}, ack_wait_ns = i64(time.Second), max_deliver = 3})
	testing.expect_value(t, e.jetstream, i32(10100))
	feature_publish(t, &f, "dlv.u.b1.prompt")
	for id in ([]string{"b1", "b2"}) {
		p, pe := pull_bind(f.conn, "FEATURE", id); testing.expect_value(t, pe.status, i32(0))
		b, _ := fetch(p, 1, 200)
		testing.expect_value(t, batch_count(b), 1 if id == "b1" else 0)
		batch_destroy(b); pull_destroy(p)
	}
}
scenario_max_ack_pending :: proc(t: ^testing.T) {
	f := feature_start(t, true, max_pending = 16); defer feature_destroy(&f)
	for _ in 0 ..< 20 do feature_publish(t, &f, "ev.pending")
	b := feature_fetch(t, &f, 20, 300); defer batch_destroy(b)
	testing.expect_value(t, batch_count(b), 16)
}
feature_reply :: proc(t: ^testing.T, f: ^Feature_Fixture) -> string {
	feature_publish(t, f, "ev.reply")
	b := feature_fetch(t, f, 1); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return ""
	return strings.clone(message_reply(batch_message(b, 0)))
}
scenario_nak_reply_delay :: proc(t: ^testing.T) {
	f := feature_start(t, true); defer feature_destroy(&f)
	reply := feature_reply(t, &f); defer delete(reply)
	started := time.tick_now()
	testing.expect_value(t, nak_reply_delay(f.conn, reply, 3000).status, i32(0)); flush(f.conn)
	b := feature_fetch(t, &f, 1, 2000); testing.expect_value(t, batch_count(b), 0); batch_destroy(b)
	b = feature_fetch(t, &f, 1, 2000); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	meta, _ := message_metadata(batch_message(b, 0))
	testing.expect(t, meta.num_delivered == 2 && time.tick_since(started) < 4 * time.Second)
}
scenario_in_progress_reply :: proc(t: ^testing.T) {
	f := feature_start(t, true, ack_wait = 2 * time.Second); defer feature_destroy(&f)
	reply := feature_reply(t, &f); defer delete(reply)
	started := time.tick_now()
	time.sleep(1500 * time.Millisecond)
	testing.expect_value(t, in_progress_reply(f.conn, reply).status, i32(0)); flush(f.conn)
	b := feature_fetch(t, &f, 1, 1500); testing.expect_value(t, batch_count(b), 0); batch_destroy(b)
	b = feature_fetch(t, &f, 1, 1400); defer batch_destroy(b)
	testing.expect(t, batch_count(b) == 1 && time.tick_since(started) < 4500 * time.Millisecond)
}
scenario_term_reply :: proc(t: ^testing.T) {
	f := feature_start(t, true, ack_wait = time.Second); defer feature_destroy(&f)
	reply := feature_reply(t, &f); defer delete(reply)
	testing.expect_value(t, term_reply(f.conn, reply).status, i32(0)); flush(f.conn)
	b := feature_fetch(t, &f, 1, 2000); defer batch_destroy(b)
	testing.expect_value(t, batch_count(b), 0); feature_count(t, &f, "ev.reply", 0)
}
scenario_ack_reply_work_queue :: proc(t: ^testing.T) {
	f := feature_start(t, true); defer feature_destroy(&f)
	reply := feature_reply(t, &f); defer delete(reply)
	testing.expect_value(t, ack_reply(f.conn, reply, 2000).status, i32(0))
	feature_count(t, &f, "ev.reply", 0)
}
scenario_ack_reply_async :: proc(t: ^testing.T) {
	f := feature_start(t, true); defer feature_destroy(&f)
	reply := feature_reply(t, &f); defer delete(reply)
	started := time.tick_now()
	testing.expect_value(t, ack_reply_async(f.conn, reply).status, i32(0))
	testing.expect(t, time.tick_since(started) < 100 * time.Millisecond)
	testing.expect_value(t, flush(f.conn).status, i32(0)); feature_count(t, &f, "ev.reply", 0)
}
scenario_delete_message :: proc(t: ^testing.T) {
	f := feature_start(t, true); defer feature_destroy(&f)
	a := feature_publish(t, &f, "ev.delete")
	deleted, err := stream_delete_message(f.conn, "FEATURE", a.sequence)
	testing.expectf(t, deleted && err.status == 0, "delete existing: %v %v", deleted, err); feature_count(t, &f, "ev.delete", 0)
	deleted, err = stream_delete_message(f.conn, "FEATURE", a.sequence)
	testing.expectf(t, !deleted && err.status == 0, "delete absent: %v %v", deleted, err)
}
scenario_delayed_nak_counts_toward_max_ack_pending :: proc(t: ^testing.T) {
	f := feature_start(t, true, max_pending = 2); defer feature_destroy(&f)
	for _ in 0 ..< 3 do feature_publish(t, &f, "ev.delayed")
	b := feature_fetch(t, &f, 2)
	if !testing.expect_value(t, batch_count(b), 2) {batch_destroy(b); return}
	for i in 0 ..< 2 do testing.expect_value(t, nak_reply_delay(f.conn, message_reply(batch_message(b, i)), 3000).status, i32(0))
	batch_destroy(b); flush(f.conn)
	b = feature_fetch(t, &f, 1, 2000); testing.expect_value(t, batch_count(b), 0); batch_destroy(b)
	b = feature_fetch(t, &f, 2, 2000); defer batch_destroy(b)
	testing.expect_value(t, batch_count(b), 2)
	for i in 0 ..< batch_count(b) {m, e := message_metadata(batch_message(b, i)); testing.expect(t, e.status == 0 && m.num_delivered == 2)}
}
scenario_max_deliver_advisory :: proc(t: ^testing.T) {
	f := feature_start(t, true, ack_wait = time.Second, max_deliver = 3); defer feature_destroy(&f)
	_, e := stream_add(f.conn, {name = "ADV", subjects = []string{"$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.FEATURE.>"}, replicas = 1, allow_direct = true})
	testing.expect_value(t, e.status, i32(0))
	a := feature_publish(t, &f, "ev.exhausted")
	for i in 0 ..< 3 {
		b := feature_fetch(t, &f, 1, 1500)
		if testing.expect_value(t, batch_count(b), 1) {m, _ := message_metadata(batch_message(b, 0)); testing.expect_value(t, m.num_delivered, u64(i+1))}
		batch_destroy(b)
	}
	b := feature_fetch(t, &f, 1, 1500); testing.expect_value(t, batch_count(b), 0); batch_destroy(b)
	state, err := stream_info(f.conn, "ADV"); testing.expect(t, err.status == 0 && state.messages == 1)
	msg, me := stream_get(f.conn, "ADV", state.first); defer message_destroy(msg)
	if !testing.expect_value(t, me.status, i32(0)) do return
	body: struct {stream, consumer: string, stream_seq: u64}
	decode := json.unmarshal(message_data(msg), &body)
	defer delete(body.stream); defer delete(body.consumer)
	testing.expect(t, decode == nil && body.stream == "FEATURE" && body.consumer == "read" && body.stream_seq == a.sequence)
	feature_count(t, &f, "ev.exhausted", 1)
}
scenario_schedule_fire_ttl :: proc(t: ^testing.T) {
	f := feature_start(t); defer feature_destroy(&f)

	feature_schedule(t, &f, "@every 1s", []Header{{"Nats-Schedule-TTL", "2s"}})
	b := feature_fetch(t, &f, 1, 3000); defer batch_destroy(b)
	if !testing.expect_value(t, batch_count(b), 1) do return
	meta, err := message_metadata(batch_message(b, 0))
	if !testing.expect_value(t, err.status, i32(0)) do return
	time.sleep(time.Second)
	msg, me := stream_get(f.conn, "FEATURE", meta.stream_sequence)
	message_destroy(msg); testing.expect_value(t, me.status, i32(0))
	time.sleep(3 * time.Second)
	old, old_err := stream_get(f.conn, "FEATURE", meta.stream_sequence)
	message_destroy(old)
	fmt.printf("scenario_schedule_fire_ttl: server honours Nats-Schedule-TTL = %v\n", old_err.status == 13)
	// The spec permits either result: T10 deletes fires if the server ignores TTL.
	testing.expect(t, old_err.status == 13 || old_err.status == 0)
	feature_count(t, &f, "sched.def.test", 1)
}

@(test)
test_delete_error_classification :: proc(t: ^testing.T) {
	cases := []struct {status, code: i32, description: cstring, absent: bool}{
		{13, 0, nil, true}, // NATS_NOT_FOUND
		{1, 10037, nil, true},
		{1, 10057, "no message found", true},
		{1, 10057, "(jsm.c:1713): no message found", true},
		{1, 10057, "storage failure", false},
		{1, 10057, "(jsm.c:1713): storage failure", false},
		{1, 10057, "no message found in damaged store", false},
		{1, 10057, nil, false},
		{1, 10059, "stream not found", false},
	}
	for c in cases {
		testing.expect_value(t, ham_nats_delete_error_absent(c.status, c.code, c.description) != 0, c.absent)
	}
}

scenario_long_pull_local_timeouts :: proc(t: ^testing.T) {
    f := feature_start(t)
    defer feature_destroy(&f)
    testing.expect_value(t, consumer_add(f.conn, {stream = "FEATURE", durable = "long", filter_subjects = []string{"ev.>"}, ack_wait_ns = i64(time.Second), max_deliver = 10}).status, i32(0))
    p, err := long_pull_bind(f.conn, "FEATURE", "long")
    if !testing.expect_value(t, err.status, i32(0)) do return
    defer long_pull_destroy(p)
    // Local timeouts and a server heartbeat do not create additional requests.
    requests := 0
    for _ in 0..<8 {
        msg, requested, e := long_pull_next(p, 1, 100)
        if requested do requests += 1
        testing.expect(t, msg == nil && e.status == 26)
    }
    testing.expect_value(t, requests, 1)
    _, err = publish(f.conn, "ev.later", test_bytes("later"))
    testing.expect_value(t, err.status, i32(0))
    received := false
    for _ in 0..<10 {
        msg, requested, e := long_pull_next(p, 1, 100)
        testing.expect(t, !requested)
        if e.status == 26 do continue
        testing.expect_value(t, e.status, i32(0))
        if msg != nil {
            testing.expect_value(t, string(message_data(msg)), "later")
            testing.expect_value(t, ack_reply_async(f.conn, message_reply(msg)).status, i32(0))
            message_destroy(msg)
            received = true
            break
        }
    }
    testing.expect(t, received)
}
