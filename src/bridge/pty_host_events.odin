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

// bridge_pty_host_events_ensure starts the single event-subscription worker once
// (idempotent). Called after the first successful spawn so there is a daemon to
// attach to. Safe to call repeatedly.
bridge_pty_host_events_ensure :: proc() {
	sync.mutex_lock(&pty_host_events_lock)
	defer sync.mutex_unlock(&pty_host_events_lock)
	if pty_host_events_started do return
	pty_host_events_started = true
	thread.run(bridge_pty_host_events_worker)
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

	// Attach to all instances the bridge currently has launched so their events
	// stream on this connection.
	if reply, lok := bridge_pty_host_list(socket); lok {
		for a in reply.agents do bridge_pty_host_attach_on(fd, a.instance_id)
		pty_host_reply_delete(reply)
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

// bridge_pty_host_attach_on sends an Attach for instance on an existing fd.
bridge_pty_host_attach_on :: proc(fd: posix.FD, instance: string) {
	frame := pty_host_encode_attach(instance)
	defer delete(frame)
	_ = pty_host_send_all(fd, frame)
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
		bridge_pty_host_handle_screen_changed(socket, reply.instance)
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
