package main

// ACP runtime capability detection (REQ-ACP-1/2).
//
// acp_runtime_v1 is advertised only while the PTY host answers Capabilities with
// piped_spawn_v1 (bridge_runtime_features). That used to be probed exactly once per
// hub connection, before the hello: a daemon that was cold, slow to start (macOS
// first-exec scanning), behind an open dependency breaker, or an older adopted build
// at that instant left acp_runtime_v1 unadvertised for the whole connection, even
// after agents were starting fine on a healthy daemon.
//
// The probe now also runs
//   - when the daemon behind the socket may have changed (pty_host_daemon_epoch moves:
//     ensure_daemon started or adopted one),
//   - on every provider scan (provider_discover), and
//   - on a backoff schedule while the latch is false,
// and a changed result is re-advertised on the live hub connection
// (bridge_acp_features_drain). Every failed outcome is logged with its reason.

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import ws "odin_test:lib/ws"

ACP_Probe_Trigger :: enum {
	Hub_Connect,
	Daemon_Restart,
	Retry,
	Provider_Scan,
}

ACP_Probe_Outcome :: enum {
	Supported,
	Daemon_Unavailable, // ensure_daemon failed: not started, not answering, or breaker open
	No_Reply,           // the Capabilities exchange produced no decodable reply in time
	Bad_Reply,          // a reply that is neither Capabilities nor Error
	Lacks_Piped_Spawn,  // the daemon answered but cannot host piped children (older build)
}

// ACP_Probe_IO is the probe's seam to the daemon, swapped by tests.
ACP_Probe_IO :: struct {
	ensure_daemon: proc() -> (string, bool),
	request:       Pty_Host_Request_Proc,
	// Retires an adopted stale daemon (pty_host_stale.odin); nil = never.
	reconcile:     proc(socket: string, probe: Pty_Host_Pipe_Probe) -> (Pty_Host_Stale_Action, Pty_Host_Stale_Reason),
}

acp_probe_io := ACP_Probe_IO{bridge_pty_host_ensure_daemon, pty_host_request_deadline, acp_probe_reconcile_default}

acp_probe_reconcile_default :: proc(socket: string, probe: Pty_Host_Pipe_Probe) -> (Pty_Host_Stale_Action, Pty_Host_Stale_Reason) {
	return bridge_pty_host_stale_reconcile(socket, probe)
}

// Backoff of the retry schedule while the latch is false. Each retry costs one ping
// and one Capabilities round trip on a live daemon.
ACP_PROBE_RETRY_MIN :: 15 * time.Second
ACP_PROBE_RETRY_MAX :: 5 * time.Minute

// bridge_acp_runtime_supported is the latch bridge_runtime_features reads.
bridge_acp_runtime_supported: bool
// bridge_acp_features_dirty: the latch changed after the last advertisement (hello or
// re-advertisement); the hub runtime loop drains it. Atomic.
bridge_acp_features_dirty: bool

acp_probe_lock: sync.Mutex
// The pty_host_daemon_epoch the last completed probe observed (atomic).
acp_probe_seen_epoch: u64
// Wall-clock ns of the next scheduled retry, 0 when none is pending (atomic).
acp_probe_next_retry_ns: i64
// Consecutive failed probes, for the retry backoff (under acp_probe_lock).
acp_probe_failures: int
// A background probe started by the loop tick is in flight (atomic single-flight).
acp_probe_running: bool

// bridge_acp_runtime_probe ensures the daemon, asks it for piped-spawn support and
// updates the latch. It blocks for up to ensure_daemon's cold-start wait plus the 2s
// Capabilities deadline, so the hub loop never calls it inline (see
// bridge_acp_runtime_probe_tick). Probes are serialized.
//
// Daemon_Unavailable keeps the last known value: launches re-check support anyway
// (acp_runtime.odin), and withdrawing the feature for a transient daemon restart
// would only flap the hub's view. Every other outcome is authoritative.
// changed reports a latch flip; it also marks the features dirty for re-advertising.
bridge_acp_runtime_probe :: proc(trigger: ACP_Probe_Trigger) -> (outcome: ACP_Probe_Outcome, changed: bool) {
	sync.mutex_lock(&acp_probe_lock)
	defer sync.mutex_unlock(&acp_probe_lock)

	socket, daemon_ok := acp_probe_io.ensure_daemon()
	probe: Pty_Host_Pipe_Probe
	if daemon_ok {
		probe = pty_host_probe_pipes(socket, acp_probe_io.request)
		// An adopted daemon left over from an older install is retired once idle and
		// the current one started and probed in its place (pty_host_stale.odin).
		if acp_probe_io.reconcile != nil {
			if action, _ := acp_probe_io.reconcile(socket, probe); action == .Replaced {
				socket, daemon_ok = acp_probe_io.ensure_daemon()
				if daemon_ok do probe = pty_host_probe_pipes(socket, acp_probe_io.request)
			}
		}
	}
	// Read AFTER ensure_daemon: the start/adoption (or replacement) this very call
	// caused must not trigger another probe.
	sync.atomic_store(&acp_probe_seen_epoch, sync.atomic_load(&pty_host_daemon_epoch))
	if !daemon_ok {
		outcome = .Daemon_Unavailable
	} else {
		switch probe {
		case .Supported:         outcome = .Supported
		case .No_Reply:          outcome = .No_Reply
		case .Bad_Reply:         outcome = .Bad_Reply
		case .Lacks_Piped_Spawn: outcome = .Lacks_Piped_Spawn
		}
	}

	previous := sync.atomic_load(&bridge_acp_runtime_supported)
	current := previous
	if outcome != .Daemon_Unavailable do current = outcome == .Supported
	if current != previous {
		sync.atomic_store(&bridge_acp_runtime_supported, current)
		sync.atomic_store(&bridge_acp_features_dirty, true)
		changed = true
	}

	now := time.to_unix_nanoseconds(time.now())
	// A stale daemon kept for its agents is re-checked on the same schedule, even
	// when it does support piped spawn (an older bin.bak build of a recent release).
	if outcome == .Supported && !sync.atomic_load(&pty_host_stale_pending) {
		acp_probe_failures = 0
		sync.atomic_store(&acp_probe_next_retry_ns, 0)
	} else {
		acp_probe_failures += 1
		sync.atomic_store(&acp_probe_next_retry_ns, now + i64(acp_probe_retry_delay(acp_probe_failures)))
	}
	acp_probe_log(trigger, outcome, previous, current)
	return
}

// acp_probe_retry_delay doubles from ACP_PROBE_RETRY_MIN up to ACP_PROBE_RETRY_MAX.
acp_probe_retry_delay :: proc(failures: int) -> time.Duration {
	delay := ACP_PROBE_RETRY_MIN
	for _ in 1 ..< max(failures, 1) {
		delay *= 2
		if delay >= ACP_PROBE_RETRY_MAX do return ACP_PROBE_RETRY_MAX
	}
	return delay
}

ACP_PROBE_TRIGGER_SYMS := [ACP_Probe_Trigger]contracts.Bridge_Log_Sym{
	.Hub_Connect    = .hello,
	.Daemon_Restart = .daemon_restart,
	.Retry          = .retry,
	.Provider_Scan  = .provider_scan,
}

ACP_PROBE_OUTCOME_SYMS := [ACP_Probe_Outcome]contracts.Bridge_Log_Sym{
	.Supported          = .other,
	.Daemon_Unavailable = .daemon_unavailable,
	.No_Reply           = .no_reply,
	.Bad_Reply          = .bad_reply,
	.Lacks_Piped_Spawn  = .lacks_piped_spawn,
}

// REQ-ACP-2: a failure is a structured bridge_log event (relayed to the hub) with the
// trigger as stage and the cause as reason; a success is a local log line, printed
// only when it changes the latch or ends a failure streak, so the periodic and
// per-scan probes of a healthy daemon stay quiet.
acp_probe_log :: proc(trigger: ACP_Probe_Trigger, outcome: ACP_Probe_Outcome, previous, current: bool) {
	if outcome != .Supported {
		blog_warn(.acp_runtime_unavailable, blog_sym(.stage, ACP_PROBE_TRIGGER_SYMS[trigger]), blog_sym(.reason, ACP_PROBE_OUTCOME_SYMS[outcome]), blog_int(.attempt, i64(acp_probe_failures)))
		return
	}
	if previous != current || trigger == .Hub_Connect {
		fmt.printfln("bridge acp runtime: piped spawn supported (probe %v); advertising %s", trigger, contracts.BRIDGE_FEATURE_ACP_RUNTIME)
	}
}

// bridge_acp_runtime_probe_tick runs on the hub loop thread every iteration. It
// starts at most one background probe when the daemon epoch moved since the last
// probe, or a scheduled retry is due. Cheap when nothing is due: three atomic loads.
bridge_acp_runtime_probe_tick :: proc(now_ns: i64) {
	trigger, due := bridge_acp_runtime_probe_due(now_ns)
	if !due do return
	if _, swapped := sync.atomic_compare_exchange_strong(&acp_probe_running, false, true); !swapped do return
	thread.run_with_poly_data(trigger, proc(trigger: ACP_Probe_Trigger) {
		defer sync.atomic_store(&acp_probe_running, false)
		_, _ = bridge_acp_runtime_probe(trigger)
	})
}

// bridge_acp_runtime_probe_due is the tick's pure decision (tests drive it).
bridge_acp_runtime_probe_due :: proc(now_ns: i64) -> (ACP_Probe_Trigger, bool) {
	if sync.atomic_load(&acp_probe_running) do return {}, false
	if sync.atomic_load(&pty_host_daemon_epoch) != sync.atomic_load(&acp_probe_seen_epoch) do return .Daemon_Restart, true
	next := sync.atomic_load(&acp_probe_next_retry_ns)
	if next != 0 && now_ns >= next do return .Retry, true
	return {}, false
}

// ACP_Advertise_Route is how a changed feature list reaches the hub on the live
// connection (contracts.BRIDGE_FEATURES_UPDATE_FRAME_TYPE).
ACP_Advertise_Route :: enum {
	None,            // nothing changed, or nothing worth a reconnect
	Features_Update, // the hub accepts bridge_features_update
	Heartbeat,       // legacy connection: a metadata-bearing beat replaces the features
	Reconnect,       // metadata omission negotiated with a hub that predates the frame
}

// bridge_hub_features_update_supported: this connection's bridge_ready carried
// contracts.BRIDGE_READY_FEATURES_UPDATE. Reset before every hello.
bridge_hub_features_update_supported: bool

// bridge_acp_advertise_route picks the route for a dirty feature list. A reconnect
// is reserved for GAINING acp_runtime_v1: the fresh hello re-probes and carries the
// new list, while a lost feature is not worth dropping the connection for (ACP
// launches re-check support and fail cleanly with unsupported_runtime_transport).
bridge_acp_advertise_route :: proc(dirty, features_update, metadata_omission, acp_supported: bool) -> ACP_Advertise_Route {
	if !dirty do return .None
	if features_update do return .Features_Update
	if !metadata_omission do return .Heartbeat
	if acp_supported do return .Reconnect
	return .None
}

// bridge_features_update_json is the bridge_features_update frame for the current
// feature list (temp-allocated).
bridge_features_update_json :: proc() -> string {
	return fmt.tprintf(`{{"type":"%s","protocol_version":1,"features":%s}}`, contracts.BRIDGE_FEATURES_UPDATE_FRAME_TYPE, bridge_runtime_features_json())
}

// bridge_acp_features_drain re-advertises a changed feature list. Hub loop thread
// only (it owns conn).
bridge_acp_features_drain :: proc(conn: ^ws.Connection) {
	// Swap first: a probe flipping the latch after this point marks it dirty again
	// and is drained on the next iteration.
	if _, was_dirty := sync.atomic_compare_exchange_strong(&bridge_acp_features_dirty, true, false); !was_dirty do return
	route := bridge_acp_advertise_route(
		true,
		sync.atomic_load(&bridge_hub_features_update_supported),
		sync.atomic_load(&bridge_hub_heartbeat_metadata_omission),
		sync.atomic_load(&bridge_acp_runtime_supported),
	)
	switch route {
	case .None:
		fmt.println("bridge acp runtime: feature list changed; this hub only learns it on the next hello")
	case .Features_Update:
		_ = ws.send_text(conn, bridge_features_update_json())
	case .Heartbeat:
		hb := bridge_hub_heartbeat_json()
		_ = ws.send_text(conn, hb)
		delete(hb)
	case .Reconnect:
		fmt.println("bridge acp runtime: ACP now supported; reconnecting so the hello re-advertises it (hub predates bridge_features_update)")
		ws.abort(conn)
	}
}

// bridge_acp_runtime_probe_on_connect is the pre-hello probe of every hub connection.
// The hello it precedes carries the result, so nothing is left to re-advertise.
bridge_acp_runtime_probe_on_connect :: proc() {
	_, _ = bridge_acp_runtime_probe(.Hub_Connect)
	sync.atomic_store(&bridge_acp_features_dirty, false)
}

// acp_probe_reset restores the module's zero state (tests).
acp_probe_reset :: proc() {
	sync.atomic_store(&bridge_acp_runtime_supported, false)
	sync.atomic_store(&bridge_acp_features_dirty, false)
	sync.atomic_store(&acp_probe_seen_epoch, sync.atomic_load(&pty_host_daemon_epoch))
	sync.atomic_store(&acp_probe_next_retry_ns, 0)
	sync.atomic_store(&acp_probe_running, false)
	acp_probe_failures = 0
}
