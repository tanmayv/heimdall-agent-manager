package main

// BR-3: ham-pty-host event subscription loop.
//
// The daemon multiplexes per-instance events on any attached connection: the
// bridge opens ONE long-lived connection, subscribes (Attach) to instances it
// launches, and reads the framed reply/event stream. Each event maps onto the
// bridge's existing status/activity surface (the same procs the wrapper endpoint
// called), so the hub sees identical semantics with no wrapper in the loop:
//
//   ChildExited   -> bridge_pty_host_apply_child_exited   (status stopped)
//   StartupReady  -> bridge_pty_host_apply_startup_ready  (liveness, stays starting)
//   StartupBlocked-> bridge_pty_host_apply_startup_blocked (status blocked)
//   ScreenChanged -> capture a burst + classify -> apply_activity (pane_diff)
//
// ScreenChanged is a cheap dirty signal (a content hash). On it the bridge
// captures a short burst of rendered screens (host.capture) a few hundred ms apart
// and runs the ported spinner-masking classifier, so a ticking footer/spinner does
// not read as false-active. This keeps the daemon dumb (raw hash) and the policy
// in the bridge, exactly as the design requires.

import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Burst shape for ScreenChanged-triggered classification. Mirrors the wrapper's
// stateless burst detector: a few frames captured a short gap apart so a slow
// token stream visibly grows (=> active) while a quiet pane's masked frames stay
// identical (=> idle).
PTY_HOST_BURST_FRAMES :: 3
PTY_HOST_BURST_GAP_MS :: 400

pty_host_events_started: bool
pty_host_events_lock: sync.Mutex

// Activity-classification work queue (BR-3): ScreenChanged handling is blocking
// (~800ms of burst captures), so it MUST NOT run in the read loop. The read loop
// enqueues (instance, socket) here and a dedicated worker drains it. The queue is
// COALESCED per instance — a pending instance is not duplicated — so a burst of
// ScreenChanged for one agent collapses to a single reclassification, bounding the
// backlog regardless of how chatty an agent is.
pty_host_activity_queue: [dynamic]string
pty_host_activity_socket: string
pty_host_activity_lock: sync.Mutex

// bridge_pty_host_events_ensure starts the single event-subscription worker AND
// the activity-classification worker once (idempotent). Called after the first
// successful spawn so there is a daemon to attach to. Safe to call repeatedly.
//
// Per-child liveness is delivered by the daemon's pushed Host_Heartbeat digest on
// the event connection (see bridge_pty_host_dispatch_event); the read loop stays
// tight (offloading blocking activity work below) so heartbeats/exits are always
// drained promptly.
bridge_pty_host_events_ensure :: proc() {
	sync.mutex_lock(&pty_host_events_lock)
	defer sync.mutex_unlock(&pty_host_events_lock)
	if pty_host_events_started do return
	pty_host_events_started = true
	pty_host_activity_queue = make([dynamic]string)
	thread.run(bridge_pty_host_events_worker)
	thread.run(bridge_pty_host_activity_worker)
}

// bridge_pty_host_enqueue_screen_changed queues an instance for activity
// reclassification, coalescing duplicates so the queue never grows unbounded under
// a chatty agent. Called from the read loop; returns immediately.
bridge_pty_host_enqueue_screen_changed :: proc(socket, instance: string) {
	if strings.trim_space(instance) == "" do return
	sync.mutex_lock(&pty_host_activity_lock)
	defer sync.mutex_unlock(&pty_host_activity_lock)
	if pty_host_activity_socket == "" do pty_host_activity_socket = strings.clone(socket)
	for id in pty_host_activity_queue do if id == instance do return
	append(&pty_host_activity_queue, strings.clone(instance))
}

// bridge_pty_host_activity_worker drains the activity queue, running the blocking
// burst-capture classification OFF the read loop so it never stalls heartbeat/exit
// delivery. It sleeps briefly when the queue is empty.
bridge_pty_host_activity_worker :: proc() {
	for {
		instance := ""
		socket := ""
		sync.mutex_lock(&pty_host_activity_lock)
		if len(pty_host_activity_queue) > 0 {
			instance = pty_host_activity_queue[0]
			ordered_remove(&pty_host_activity_queue, 0)
			socket = pty_host_activity_socket
		}
		sync.mutex_unlock(&pty_host_activity_lock)
		if instance == "" {
			time.sleep(100 * time.Millisecond)
			continue
		}
		bridge_pty_host_handle_screen_changed(socket, instance)
		delete(instance)
	}
}

// bridge_pty_host_events_worker is the long-lived reader. It (re)dials the daemon,
// subscribes to all currently-registered instances, and reads the event stream,
// dispatching each event. On disconnect it backs off and reconnects; the daemon
// (and its children) outlive a bridge reconnect.
bridge_pty_host_events_worker :: proc() {
	for {
		socket := pty_host_socket_path()
		if !bridge_pty_host_events_run_once(socket) {
			time.sleep(500 * time.Millisecond)
		}
	}
}

// bridge_pty_host_events_run_once opens one connection, attaches to every known
// instance, then reads+dispatches until the connection drops. Returns false on a
// failed dial so the caller backs off.
bridge_pty_host_events_run_once :: proc(socket: string) -> bool {
	fd, ok := pty_host_dial(socket)
	if !ok do return false
	defer posix.close(fd)

	// Subscribe to host-level events (WatchEvents) instead of Attaching. The daemon
	// then delivers all bridge-relevant frames — HostHeartbeat, ChildExited,
	// ScreenChanged, StartupReady/Blocked — for ALL agents on this one connection,
	// WITHOUT the raw per-instance PTY Output flood that Attach would add. That
	// Output flood previously stalled this single-threaded read loop and delayed
	// heartbeat/exit processing, falsely reaping idle agents. Output stays
	// Attach-gated for the UI live-pane path only.
	{
		frame := pty_host_encode_watch_events()
		defer delete(frame)
		if !pty_host_send_all(fd, frame) do return true
	}

	for {
		payload, pok := pty_host_read_frame(fd)
		if !pok do return true // clean disconnect; caller will reconnect
		reply, dok := pty_host_decode_reply(payload)
		delete(payload)
		if !dok do continue
		bridge_pty_host_dispatch_event(socket, reply)
		pty_host_reply_delete(reply)
	}
}

// bridge_pty_host_dispatch_event routes one decoded event to the status/activity
// surface. Output/Screen/Pong/ack replies are ignored here (control-plane replies
// are consumed by their request callers); this loop cares about async events.
bridge_pty_host_dispatch_event :: proc(socket: string, reply: Pty_Host_Reply) {
	#partial switch reply.kind {
	case .Child_Exited:
		bridge_pty_host_apply_child_exited(reply.instance, reply.code)
	case .Startup_Ready:
		bridge_pty_host_apply_startup_ready(reply.instance)
	case .Startup_Blocked:
		bridge_pty_host_apply_startup_blocked(reply.instance, reply.reason_code, reply.message)
	case .Screen_Changed:
		// Do NOT run the burst-capture classification inline: it blocks ~800ms+
		// (3 captures * 400ms gaps) and would stall the single-threaded read loop,
		// starving Host_Heartbeat / Child_Exited frames that pile up unread behind
		// it — which caused idle agents to be falsely reaped while a busy agent's
		// ScreenChanged stream monopolized the loop. Hand off to the activity worker
		// (coalesced per instance) and keep reading.
		bridge_pty_host_enqueue_screen_changed(socket, reply.instance)
	case .Host_Heartbeat:
		// Per-child liveness digest pushed by the daemon on a fixed cadence:
		// refresh last_seen for every child the daemon reports alive. A dead child
		// reports alive=false (or drops from the roster) and stops being touched,
		// so it is still correctly reaped; ChildExited remains the instant path.
		for a in reply.heartbeat_agents {
			if a.alive do bridge_runtime_touch_liveness(a.instance_id)
		}
	}
}

// bridge_pty_host_handle_screen_changed captures a short burst of rendered screens
// for instance and classifies activity from it (spinner-masked), then reports to
// the hub. The dirty signal only tells us SOMETHING changed; the burst + masking
// decide whether that is genuine work or just a ticking footer/spinner.
bridge_pty_host_handle_screen_changed :: proc(socket, instance: string) {
	frames := make([]string, PTY_HOST_BURST_FRAMES)
	got := 0
	for i in 0..<PTY_HOST_BURST_FRAMES {
		if text, ok := bridge_pty_host_capture_text(socket, instance); ok {
			frames[got] = text
			got += 1
		}
		if i < PTY_HOST_BURST_FRAMES - 1 do time.sleep(PTY_HOST_BURST_GAP_MS * time.Millisecond)
	}
	defer {
		for i in 0..<got do delete(frames[i])
		delete(frames)
	}
	if got == 0 do return
	sample := bridge_activity_burst_status(frames[:got])
	bridge_pty_host_apply_activity(instance, sample)
}

// bridge_pty_host_capture_text requests one screen snapshot and joins its lines
// into a single frame string. Caller owns the returned string.
bridge_pty_host_capture_text :: proc(socket, instance: string) -> (string, bool) {
	frame := pty_host_encode_capture(instance)
	defer delete(frame)
	reply, ok := pty_host_request(socket, frame)
	if !ok do return "", false
	defer pty_host_reply_delete(reply)
	if reply.kind != .Screen do return "", false
	return bridge_activity_screen_to_text(reply.screen.lines), true
}
