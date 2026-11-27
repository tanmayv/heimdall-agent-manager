package main

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"
import ws "odin_test:lib/ws"

@(test)
test_stream_titles_are_readable_and_do_not_expose_data_urls :: proc(t: ^testing.T) {
	testing.expect_value(t, stream_cdp_title("  DaTa:text/html,<h1>private fixture</h1>"), "Data URL tab")
	testing.expect_value(t, stream_cdp_title(""), "Browser tab")
	testing.expect_value(t, stream_cdp_title("  A short title  "), "A short title")
	testing.expect_value(t, stream_cdp_title("Visible title\nHidden suffix"), "Visible title…")
	prefix := strings.repeat("🙂", 49, context.temp_allocator)
	long := strings.concatenate({prefix, "🙂 tail"}, context.temp_allocator)
	testing.expect_value(t, stream_cdp_title(long), strings.concatenate({prefix, "…"}, context.temp_allocator))
}

@(test)
test_stream_profile_identity_and_port :: proc(t: ^testing.T) {
	profile := "/fixture/bridge-one"
	other := "/fixture/bridge-two"
	port := stream_profile_port(profile, 0)
	testing.expect(t, port >= 20000 && port <= 59999)
	testing.expect_value(t, port, stream_profile_port(profile, 0))
	testing.expect(t, port != stream_profile_port(other, 0))
	testing.expect_value(t, stream_profile_port(profile, 47222), u16(47222))
	testing.expect(t, stream_cdp_identity_matches({"chromium", "--user-data-dir", profile}, profile))
	testing.expect(t, !stream_cdp_identity_matches({"chromium", "--user-data-dir=/fixture/bridge-two"}, profile))
	testing.expect(t, !stream_cdp_identity_matches({"chromium", "--user-data-dir=/fixture/bridge-one", "--user-data-dir=/fixture/bridge-two"}, profile))
	testing.expect(t, !stream_cdp_identity_matches({"chromium", "--remote-debugging-port=9222"}, profile))
}

@(test)
test_stream_rolling_limits :: proc(t: ^testing.T) {
	budget: Stream_Budget
	start := time.Tick{_nsec = i64(time.Second)}
	testing.expect(t, stream_budget_admit(&budget, start, 600_000))
	testing.expect(t, !stream_budget_admit(&budget, time.Tick{_nsec = start._nsec + i64(124 * time.Millisecond)}, 1))
	testing.expect(t, !stream_budget_admit(&budget, time.Tick{_nsec = start._nsec + i64(999 * time.Millisecond)}, 400_001))
	testing.expect(t, stream_budget_admit(&budget, time.Tick{_nsec = start._nsec + i64(time.Second)}, 1_000_000))
	testing.expect(t, !stream_budget_admit(&budget, time.Tick{_nsec = start._nsec + i64(1500 * time.Millisecond)}, 1))
}

// Explicitly opt in by pointing at a Chromium executable, for example through
// the pinned Nix package. No live profile, browser, Hub or credentials are used.
@(test)
test_stream_headless_capture :: proc(t: ^testing.T) {
	binary := os.get_env("HEIMDALL_TEST_CHROMIUM", context.temp_allocator)
	if binary == "" do return
	root, root_err := bridge_browser_test_root()
	if !testing.expect(t, root_err == nil) do return
	defer { _ = os.remove_all(root); delete(root) }
	profile := fmt.tprintf("%s/profile", root)
	html := fmt.tprintf("%s/fixture.html", root)
	body := string(`<!doctype html><body><script>
let i=0;function draw(){document.body.style.background = (i++%2 ? '#114477' : '#ee3344');requestAnimationFrame(draw)}draw()
</script>`)
	if !testing.expect(t, os.write_entire_file(html, transmute([]byte)body) == nil) do return
	argv := []string{binary, "--headless", "--disable-gpu", "--disable-dev-shm-usage", "--no-sandbox",
		"--no-first-run", "--disable-background-networking", "--disable-component-update", "--disable-sync",
		"--enable-automation", "--remote-debugging-port=0", fmt.tprintf("--user-data-dir=%s", profile), fmt.tprintf("file://%s", html)}
	child, launch_err := os.process_start({command = argv})
	if !testing.expect(t, launch_err == nil, "could not launch fixture Chromium") do return
	defer { _ = os.process_kill(child); _, _ = os.process_wait(child, time.Second) }
	port: u16
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		port = stream_cdp_profile_port(profile)
		if port != 0 do break
		time.sleep(10 * time.Millisecond)
	}
	if !testing.expect(t, port != 0, "fixture endpoint did not appear") do return
	foreign_conn, identity := stream_cdp_verified(port, fmt.tprintf("%s/other", root))
	if identity == .Verified do httpc.websocket_close(&foreign_conn)
	if !testing.expect_value(t, identity, Stream_Identity.Foreign) do return
	conn, own_identity := stream_cdp_verified(port, profile)
	if !testing.expect_value(t, own_identity, Stream_Identity.Verified) do return
	defer httpc.websocket_close(&conn)
	tabs, ok := stream_cdp_tabs(&conn)
	if !testing.expect(t, ok && len(tabs) == 1, "expected one fixture tab") do return
	live := Stream_Live{profile = profile, port = port,
		reg = {stream_id = "0123456789abcdef0123456789abcdef", source = {kind = contracts.STREAM_SOURCE_BROWSER_TAB, ref = tabs[0].id}}}
	worker := thread.create_and_start_with_data(&live, stream_capture_worker)
	if !testing.expect(t, worker != nil) do return
	defer if worker != nil do stream_test_stop_worker(&live, worker)

	start = time.tick_now()
	jpeg: []byte
	failure: string
	for time.tick_since(start) < 5 * time.Second {
		sync.mutex_lock(&stream_mu)
		if live.pending != nil { jpeg = make([]byte, len(live.pending)); copy(jpeg, live.pending) }
		done := live.reason != ""
		failure = live.source_stage
		sync.mutex_unlock(&stream_mu)
		if jpeg != nil || done do break
		time.sleep(10 * time.Millisecond)
	}
	defer delete(jpeg)
	if !testing.expect(t, len(jpeg) > 2 && jpeg[0] == 0xff && jpeg[1] == 0xd8, fmt.tprintf("expected JPEG frame (capture stage: %s)", failure)) do return
	count := (len(jpeg) + contracts.STREAM_MAX_PIECE_BYTES - 1) / contracts.STREAM_MAX_PIECE_BYTES
	for i in 0..<count {
		start := i * contracts.STREAM_MAX_PIECE_BYTES
		data := jpeg[start:min(start + contracts.STREAM_MAX_PIECE_BYTES, len(jpeg))]
		wire := contracts.stream_encode_piece({live.reg.stream_id, 1, u16(i), u16(count), contracts.STREAM_MIME_JPEG, data})
		defer delete(wire)
		piece, valid := contracts.stream_decode_piece(wire)
		testing.expect(t, valid && len(piece.data) == len(data))
	}
	stream_test_stop_worker(&live, worker)
	worker = nil
	if !testing.expect_value(t, live.reason, "") do return

	// Reattach to the same tab and close it from a separate verified CDP
	// connection. The worker must observe source closure, rather than timeout.
	live.worker_stop = false
	worker = thread.create_and_start_with_data(&live, stream_capture_worker)
	if !testing.expect(t, worker != nil) do return
	start = time.tick_now()
	ready := false
	for time.tick_since(start) < 5 * time.Second {
		sync.mutex_lock(&stream_mu)
		ready = live.pending != nil
		failed := live.reason != ""
		sync.mutex_unlock(&stream_mu)
		if ready || failed do break
		time.sleep(10 * time.Millisecond)
	}
	if !testing.expect(t, ready, "no frame after reattach") do return
	if !testing.expect(t, stream_cdp_command(&conn, 10, "", "Target.closeTarget", struct {targetId: string}{tabs[0].id})) do return
	start = time.tick_now()
	reason := ""
	for time.tick_since(start) < 5 * time.Second {
		sync.mutex_lock(&stream_mu)
		reason = live.reason
		sync.mutex_unlock(&stream_mu)
		if reason != "" do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, reason, "source_closed")

}

stream_test_stop_worker :: proc(live: ^Stream_Live, worker: ^thread.Thread) {
	sync.mutex_lock(&stream_mu)
	live.worker_stop = true
	sync.mutex_unlock(&stream_mu)
	thread.join(worker)
	thread.destroy(worker)
	delete(live.pending, runtime.heap_allocator())
	live.pending = nil
}

stream_test_decode_piece :: proc(_: ^ws.Connection, wire: []byte) -> bool {
	piece, ok := contracts.stream_decode_piece(wire)
	return ok && piece.piece_count == 2 && piece.data[0] == 0x42
}

@(test)
test_stream_latest_frame_and_ack_after_final_piece :: proc(t: ^testing.T) {
	live := Stream_Live{reg = {stream_id = "0123456789abcdef0123456789abcdef"}}
	defer { delete(live.pending, runtime.heap_allocator()); delete(live.sending, runtime.heap_allocator()) }
	stale := make([]byte, contracts.STREAM_MAX_PIECE_BYTES + 1, runtime.heap_allocator())
	latest := make([]byte, contracts.STREAM_MAX_PIECE_BYTES + 1, runtime.heap_allocator())
	for &b in latest do b = 0x42
	testing.expect_value(t, stream_offer_frame(&live, stale, 1), 0)
	testing.expect_value(t, stream_offer_frame(&live, latest, 2), 1)
	if !testing.expect(t, stream_send_piece(nil, &live, stream_test_decode_piece)) do return
	testing.expect_value(t, live.acked, 0)
	if !testing.expect(t, stream_send_piece(nil, &live, stream_test_decode_piece)) do return
	testing.expect_value(t, live.acked, 1)
	testing.expect_value(t, live.ack_session, 2)
}

Stream_Test_Control_Record :: struct { registered, ended: int, reason: string }
stream_test_record_control :: proc(conn: ^ws.Connection, control: contracts.Stream_Control) -> bool {
	out := cast(^Stream_Test_Control_Record)conn
	#partial switch frame in control {
	case contracts.Stream_Registration: out.registered += 1
	case contracts.Stream_Ended: out.ended += 1; out.reason = frame.reason
	}
	return true
}
stream_test_instance_live :: proc(_: string, _: int) -> bool { return true }

stream_test_registry_mu: sync.Mutex

@(test)
test_stream_registration_reconnect_stop_and_expiry :: proc(t: ^testing.T) {
	sync.mutex_lock(&stream_test_registry_mu)
	defer sync.mutex_unlock(&stream_test_registry_mu)
	stream_connection(true)
	defer {
		stream_connection(false)
		sync.mutex_lock(&stream_mu)
		for &slot in stream_live {
			if slot != nil { stream_free(slot); slot = nil }
		}
		sync.mutex_unlock(&stream_mu)
	}
	id := "0123456789abcdef0123456789abcdef"
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = "inst_test", run_count = 1}
	live, created := stream_local_register(id, "owner", rec, "task", {"fixture", "", "page"}, 42000, "/fixture", "fixture-link", stream_test_instance_live)
	if !testing.expect(t, live != nil && created) do return
	live.share_waiters -= 1
	defer free_all(context.temp_allocator)
	trace: Stream_Test_Control_Record
	probe := cast(^ws.Connection)&trace
	_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	testing.expect_value(t, trace.registered, 1)
	stream_connection(false)
	stream_connection(true)
	_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	testing.expect_value(t, trace.registered, 2)
	raw := contracts.stream_encode_control(contracts.Stream_Stop{id}, context.temp_allocator)
	testing.expect(t, stream_hub_receive(string(raw)))
	_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	testing.expect_value(t, trace.ended, 1)
	testing.expect_value(t, trace.reason, "stopped")

	live, created = stream_local_register(id, "owner", rec, "task", {"fixture", "", "page"}, 42000, "/fixture", "fixture-link", stream_test_instance_live)
	if !testing.expect(t, live != nil && created) do return
	live.share_waiters -= 1
	_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	sync.mutex_lock(&stream_mu)
	if live := stream_find_locked(id); live != nil do live.reg.expires = 1
	sync.mutex_unlock(&stream_mu)
	_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	testing.expect_value(t, trace.ended, 2)
	testing.expect_value(t, trace.reason, "expired")
	// The drain may run before the share caller observes the negative ACK.
	for code in ([]string{"unauthorized", "limit", "duplicate", "invalid"}) {
		live, created = stream_local_register(id, "owner", rec, "task", {"fixture", "", "page"}, 42000, "/fixture", "fixture-link", stream_test_instance_live)
		if !testing.expect(t, live != nil && created) do return
		_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
		ack := contracts.stream_encode_control(contracts.Stream_Register_Ack{id, false, code}, context.temp_allocator)
		testing.expect(t, stream_hub_receive(string(ack)))
		_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
		sync.mutex_lock(&stream_mu)
		live := stream_find_locked(id)
		got := ""
		if live != nil {
			got = live.register_reject
			live.share_waiters -= 1
		}
		sync.mutex_unlock(&stream_mu)
		testing.expect_value(t, got, code)
		// In particular, a duplicate rejection cannot end the original route.
		testing.expect_value(t, trace.ended, 2)
		_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	}
}

Stream_Test_Share :: struct {
	id, tab, instance, link: string,
	live: ^Stream_Live,
	created: bool,
}

stream_test_share :: proc(data: rawptr) {
	r := cast(^Stream_Test_Share)data
	rec := Bridge_Local_Agent_Token_Record{agent_instance_id = r.instance, run_count = 1}
	r.live, r.created = stream_local_register(r.id, "owner", rec, "", {r.tab, "", "page"}, 42000, "/fixture", r.link, stream_test_instance_live)
}

@(test)
test_stream_share_reuses_pending_and_accepted_source :: proc(t: ^testing.T) {
	sync.mutex_lock(&stream_test_registry_mu)
	defer sync.mutex_unlock(&stream_test_registry_mu)
	stream_connection(true)
	defer {
		stream_connection(false)
		sync.mutex_lock(&stream_mu)
		for &slot in stream_live {
			if slot != nil { stream_free(slot); slot = nil }
		}
		sync.mutex_unlock(&stream_mu)
	}
	first := Stream_Test_Share{id = "0123456789abcdef0123456789abcdef", tab = "tab-a", instance = "first", link = "https://one.test/#/streams/0123456789abcdef0123456789abcdef"}
	second := Stream_Test_Share{id = "fedcba9876543210fedcba9876543210", tab = first.tab, instance = "second", link = "https://two.test/#/streams/fedcba9876543210fedcba9876543210"}
	// Both callers contend for the unclaimed source before either can proceed.
	sync.mutex_lock(&stream_mu)
	a := thread.create_and_start_with_data(&first, stream_test_share)
	b := thread.create_and_start_with_data(&second, stream_test_share)
	sync.mutex_unlock(&stream_mu)
	if a != nil { thread.join(a); thread.destroy(a) }
	if b != nil { thread.join(b); thread.destroy(b) }
	if !testing.expect(t, a != nil && b != nil && first.live != nil && first.live == second.live && first.created != second.created) do return

	trace: Stream_Test_Control_Record
	probe := cast(^ws.Connection)&trace
	_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
	testing.expect_value(t, trace.registered, 1)
	winner := first
	if second.created do winner = second
	ack := contracts.stream_encode_control(contracts.Stream_Register_Ack{winner.id, true, ""}, context.temp_allocator)
	testing.expect(t, stream_hub_receive(string(ack)))
	for _ in 0..<2 {
		response := stream_share_wait("request", winner.live, false, stream_test_instance_live)
		testing.expect(t, strings.contains(response, winner.link))
		delete(response)
	}
	slots := [?]Stream_Test_Share{
		{id = "22222222222222222222222222222222", tab = "tab-b"},
		{id = "33333333333333333333333333333333", tab = "tab-c"},
		{id = "44444444444444444444444444444444", tab = "tab-d"},
	}
	for &req in slots {
		stream_test_share(&req)
		testing.expect(t, req.created)
	}
	repeat := Stream_Test_Share{id = "55555555555555555555555555555555", tab = winner.tab, link = "wrong-link"}
	stream_test_share(&repeat)
	if !testing.expect(t, repeat.live == winner.live && !repeat.created) do return
	response := stream_share_wait("repeat", repeat.live, false, stream_test_instance_live)
	testing.expect(t, strings.contains(response, winner.link))
	delete(response)
	overflow := Stream_Test_Share{id = repeat.id, tab = "tab-e"}
	stream_test_share(&overflow)
	testing.expect(t, overflow.live == nil)

	// Drive the captured end states through the real drain, without starting Chromium.
	for reason in ([]string{"stopped", "expired", "source_closed"}) {
		if reason == "stopped" {
			stop := contracts.stream_encode_control(contracts.Stream_Stop{winner.id}, context.temp_allocator)
			testing.expect(t, stream_hub_receive(string(stop)))
		}
		sync.mutex_lock(&stream_mu)
		if reason == "expired" {
			winner.live.reg.expires = 1
		} else if reason == "source_closed" {
			winner.live.reason = reason
		}
		winner.live.share_waiters = 0
		sync.mutex_unlock(&stream_mu)
		_ = stream_hub_drain(probe, stream_test_record_control, stream_test_instance_live)
		previous := winner.id
		winner.id = first.id if previous != first.id else second.id
		stream_test_share(&winner)
		if !testing.expect(t, winner.created && winner.live.reg.stream_id != previous) do return
	}
}
