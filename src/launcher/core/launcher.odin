// The launcher's decision loop (docs/specs/bridge-supervisor-engine.md §7.1, §7.2).
// It starts the supervisor of `current`, watches READY, the exit code, known-good and
// the T_commit deadline, and falls back to `previous`. It has no network, channel,
// download, journal or manifest-signature logic by construction: this package imports
// nothing beyond core.
package launcher_core

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

EXIT_STOP :: 0
EXIT_HANDOVER :: 75
EXIT_REFUSE :: 78

Timeouts :: struct {
	ready:         time.Duration, // T_ready: READY after launch (spec §19: 30 s)
	commit:        time.Duration, // T_commit: unproven current must become known-good (270 s)
	known_good:    time.Duration, // known-good re-read interval while C is unproven (5 s)
	stop_grace:    time.Duration, // supervisor stop budget before kill (20 s)
	refuse_wait:   time.Duration, // sleep before exiting 78 (60 s)
	backoff_min:   time.Duration, // crash restart backoff (1 s)
	backoff_max:   time.Duration, // (5 min)
	healthy_reset: time.Duration, // a READY run this long resets the backoff (60 s)
	session_end:   time.Duration, // Windows session-end budget (4 s)
	tick:          time.Duration, // poll interval
}

DEFAULT_TIMEOUTS :: Timeouts {
	ready         = 30 * time.Second,
	commit        = 270 * time.Second,
	known_good    = 5 * time.Second,
	stop_grace    = 20 * time.Second,
	refuse_wait   = 60 * time.Second,
	backoff_min   = 1 * time.Second,
	backoff_max   = 5 * time.Minute,
	healthy_reset = 60 * time.Second,
	session_end   = 4 * time.Second,
	tick          = 100 * time.Millisecond,
}

Launch_Mode :: enum {
	Normal,
	Fallback,
}

Config :: struct {
	instance_root: string,
	state_root:    string,
	timeouts:      Timeouts,
}

Launcher :: struct {
	cfg:           Config,
	instance:      Instance_Record,
	started_unix:  i64,
	fallback_flag: bool,
	deadlines:     map[string]time.Tick,
	crash_count:   int, // total failures this launcher lifetime (diagnostics)
	crash_streak:  int, // consecutive failures, drives the backoff
	handover_streak: int,
	last_exit:     Exit_Info,
	last_decision: string,
}

Exit_Info :: struct {
	tree:   string,
	mode:   Launch_Mode,
	code:   int,
	signal: int,
	reason: string,
	at:     i64,
}

Decision :: struct {
	tree:     string,
	mode:     Launch_Mode,
	unproven: bool,
	refuse:   string, // non-empty: nothing to start, exit 78 with this reason
	note:     string,
}

// decide is the start choice of spec §7.2, as a pure function of the flag and the
// three re-read records.
decide :: proc(fallback_flag: bool, r: Records) -> Decision {
	C, P, K := r.current, r.previous, r.known_good
	switch {
	case fallback_flag && P != "":
		return {tree = P, mode = .Fallback, note = "fallback"}
	case C == "":
		if P != "" do return {tree = P, mode = .Fallback, note = "current_invalid"}
		if K != "" do return {tree = K, mode = .Normal, note = "current_and_previous_invalid"}
		return {refuse = "no_valid_tree"}
	case C == K:
		return {tree = C, mode = .Normal, note = "known_good"}
	case:
		return {tree = C, mode = .Normal, unproven = true, note = "unproven"}
	}
}

Run_Outcome :: enum {
	Stop_Requested,
	Exit_Stop,
	Exit_Handover,
	Exit_Refuse,
	Crash,
	Spawn_Failed,
	Ready_Timeout,
	Commit_Deadline,
}

Run_Result :: struct {
	outcome:      Run_Outcome,
	code:         int,
	signal:       int,
	ready:        bool,
	ready_for:    time.Duration,
	still_unproven: bool,
	detail:       string,
}

log :: proc(format: string, args: ..any) {
	fmt.eprintf("ham-launcher: ")
	fmt.eprintfln(format, ..args)
}

// run is the whole launcher. It returns the process exit code.
run :: proc(cfg: Config) -> int {
	l := Launcher{cfg = cfg}
	l.started_unix = time.time_to_unix(time.now())
	l.deadlines = make(map[string]time.Tick)
	defer delete(l.deadlines)

	rec, reason := read_instance_record(cfg.instance_root)
	if reason == "" do reason = check_instance_record(rec, cfg.instance_root, cfg.state_root)
	if reason != "" {
		log("refusing to run: %s", reason)
		l.last_decision = reason
		write_status(&l, "refused", "", .Normal, reason)
		return refuse_exit(&l)
	}
	l.instance = rec
	if !platform_init(&l) {
		log("platform init failed")
		write_status(&l, "refused", "", .Normal, "platform_init_failed")
		return refuse_exit(&l)
	}
	defer platform_shutdown(&l)
	discard_stale_stop_request(&l)
	clear_deadlines(&l) // spec §7.2: cleared when the launcher starts

	for {
		free_all(context.temp_allocator)
		if stop_requested(&l) do return EXIT_STOP
		records := read_records(cfg.instance_root)
		if l.fallback_flag && records.previous == "" {
			// The fallback tree vanished; decide again from the records alone.
			log("fallback tree no longer valid; clearing fallback flag")
			l.fallback_flag = false
		}
		d := decide(l.fallback_flag, records)
		if d.refuse != "" {
			log("no supervisor can start: %s (current: %s)", d.refuse, records.why_current_invalid)
			write_status(&l, "refused", "", .Normal, d.refuse)
			return refuse_exit(&l)
		}
		if records.current == records.known_good && records.current != "" do clear_deadlines(&l)
		if d.unproven {
			if _, has := l.deadlines[d.tree]; !has {
				l.deadlines[strings.clone(d.tree)] = time.tick_add(time.tick_now(), cfg.timeouts.commit)
			}
		}
		if d.note == "current_invalid" do log("current invalid (%s); starting previous %s in fallback mode", records.why_current_invalid, d.tree)
		l.last_decision = d.note
		res := supervise(&l, d)
		delete(l.last_exit.tree)
		delete(l.last_exit.reason)
		l.last_exit = {
			tree   = strings.clone(d.tree),
			mode   = d.mode,
			code   = res.code,
			signal = res.signal,
			reason = fmt.aprint(res.outcome),
			at     = time.time_to_unix(time.now()),
		}
		switch res.outcome {
		case .Stop_Requested, .Exit_Stop:
			write_status(&l, "stopped", d.tree, d.mode, "")
			return EXIT_STOP
		case .Exit_Handover:
			l.fallback_flag = false
			l.crash_streak = 0
			l.handover_streak += 1
			if l.handover_streak > 3 {
				// A supervisor that only ever hands over must not spin the CPU.
				if wait_interruptible(&l, cfg.timeouts.backoff_min) do return EXIT_STOP
			}
			continue
		case .Exit_Refuse, .Crash, .Spawn_Failed, .Ready_Timeout, .Commit_Deadline:
		}
		l.handover_streak = 0
		l.crash_count += 1
		if res.ready && res.ready_for >= cfg.timeouts.healthy_reset do l.crash_streak = 0
		l.crash_streak += 1
		if res.still_unproven {
			if records.previous != "" && records.previous != d.tree {
				log("supervisor of unproven %s failed (%v %s); falling back to %s", d.tree, res.outcome, res.detail, records.previous)
				l.fallback_flag = true
				clear_deadlines(&l)
				l.crash_streak = 0
				write_status(&l, "fallback", records.previous, .Fallback, fmt.tprint(res.outcome))
				continue
			}
			log("supervisor of unproven %s failed (%v %s); no other tree, restarting it", d.tree, res.outcome, res.detail)
		} else if res.outcome == .Exit_Refuse && records.current != "" && records.current == records.known_good && d.tree == records.current {
			// spec §7.1: 78 while C = K = sleep 60 s and exit 78 (the service manager
			// restarts with its own backoff). While C != K it is a failure (above/below).
			log("supervisor of %s refuses to run (exit 78)", d.tree)
			write_status(&l, "refused", d.tree, d.mode, "supervisor_refused")
			return refuse_exit(&l)
		} else {
			log("supervisor of %s failed (%v %s); restarting", d.tree, res.outcome, res.detail)
		}
		delay := backoff(cfg.timeouts, l.crash_streak)
		write_status(&l, "backoff", d.tree, d.mode, fmt.tprint(res.outcome))
		if wait_interruptible(&l, delay) do return EXIT_STOP
	}
}

clear_deadlines :: proc(l: ^Launcher) {
	for k in l.deadlines do delete(k)
	clear(&l.deadlines)
}

backoff :: proc(t: Timeouts, streak: int) -> time.Duration {
	d := t.backoff_min
	for _ in 1 ..< max(streak, 1) {
		d *= 2
		if d >= t.backoff_max do return t.backoff_max
	}
	return min(d, t.backoff_max)
}

refuse_exit :: proc(l: ^Launcher) -> int {
	if wait_interruptible(l, l.cfg.timeouts.refuse_wait) do return EXIT_STOP
	return EXIT_REFUSE
}

// wait_interruptible sleeps d; returns true if a stop was requested meanwhile.
wait_interruptible :: proc(l: ^Launcher, d: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < d {
		if stop_requested(l) do return true
		time.sleep(min(l.cfg.timeouts.tick, d - time.tick_since(start)))
	}
	return stop_requested(l)
}

supervise :: proc(l: ^Launcher, d: Decision) -> (res: Run_Result) {
	t := l.cfg.timeouts
	write_status(l, "starting", d.tree, d.mode, d.note)
	child, err := spawn_supervisor(l, d.tree, d.mode)
	if err != "" {
		log("cannot start supervisor of %s: %s", d.tree, err)
		res.outcome = .Spawn_Failed
		res.detail = err
		res.still_unproven = d.unproven
		return
	}
	defer release_child(&child)
	log("started supervisor of %s (%v, pid %d)", d.tree, d.mode, child.pid)
	unproven := d.unproven
	start := time.tick_now()
	ready_at: time.Tick
	last_kg := start
	for {
		if stop_requested(l) {
			graceful_stop(l, &child)
			res.outcome = .Stop_Requested
			return
		}
		if exited, code, sig := poll_child(&child); exited {
			res.code = code
			res.signal = sig
			res.ready = child.ready
			if child.ready do res.ready_for = time.tick_diff(ready_at, time.tick_now())
			res.still_unproven = unproven
			kill_child(&child) // reap anything left in its group / job
			switch {
			case sig == 0 && code == EXIT_STOP:
				res.outcome = .Exit_Stop
			case sig == 0 && code == EXIT_HANDOVER:
				res.outcome = .Exit_Handover
			case sig == 0 && code == EXIT_REFUSE:
				res.outcome = .Exit_Refuse
			case:
				res.outcome = .Crash
			}
			res.detail = fmt.tprintf("code %d signal %d", code, sig)
			log("supervisor of %s exited (code %d, signal %d)", d.tree, code, sig)
			return
		}
		if !child.ready {
			if line, got := poll_ready(&child, d.tree); got {
				child.ready = true
				ready_at = time.tick_now()
				log("supervisor of %s ready: %s", d.tree, line)
				write_status(l, "running", d.tree, d.mode, d.note)
			} else if time.tick_since(start) >= t.ready {
				log("supervisor of %s did not report READY within %v", d.tree, t.ready)
				terminate_child(l, &child)
				res.outcome = .Ready_Timeout
				res.still_unproven = unproven
				return
			}
		}
		if unproven {
			if time.tick_since(last_kg) >= t.known_good {
				last_kg = time.tick_now()
				if kg, ok := read_known_good(l.cfg.instance_root); ok && kg == d.tree {
					if valid, _ := tree_valid(l.cfg.instance_root, kg); valid {
						log("%s is now known-good", d.tree)
						unproven = false
						clear_deadlines(l)
						write_status(l, "running", d.tree, d.mode, "known_good")
					}
				}
			}
			if deadline, has := l.deadlines[d.tree]; unproven && has && time.tick_diff(deadline, time.tick_now()) >= 0 {
				log("%s did not become known-good within T_commit", d.tree)
				terminate_child(l, &child)
				res.outcome = .Commit_Deadline
				res.still_unproven = true
				return
			}
		}
		time.sleep(t.tick)
	}
}

// terminate_child stops a failed supervisor at once (spec §7.2 "terminate C's job /
// process group, wait for exit").
terminate_child :: proc(l: ^Launcher, c: ^Child) {
	kill_child(c)
	wait_child(c, l.cfg.timeouts.stop_grace)
}

// graceful_stop forwards a service stop (spec §7.3): request, wait the stop grace,
// then kill.
graceful_stop :: proc(l: ^Launcher, c: ^Child) {
	request_child_stop(l, c)
	if !wait_child(c, l.cfg.timeouts.stop_grace) {
		log("supervisor did not stop within %v; killing it", l.cfg.timeouts.stop_grace)
	}
	kill_child(c)
	wait_child(c, l.cfg.timeouts.stop_grace)
}

wait_child :: proc(c: ^Child, d: time.Duration) -> bool {
	start := time.tick_now()
	for {
		if exited, _, _ := poll_child(c); exited do return true
		if time.tick_since(start) >= d do return false
		time.sleep(20 * time.Millisecond)
	}
}

// supervisor_args is the command line of spec §7.1.
supervisor_args :: proc(l: ^Launcher, tree: string, mode: Launch_Mode, ready_fd: string) -> []string {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, join(l.cfg.instance_root, "releases", tree, SUPERVISOR_EXE))
	append(&args, "run", "--instance-root", l.cfg.instance_root, "--state-root", l.cfg.state_root)
	append(&args, "--launched-tree", tree, "--launch-mode", "fallback" if mode == .Fallback else "normal")
	append(&args, "--ready-fd", ready_fd)
	return args[:]
}

// check_ready_line validates "READY <T> <engine_version> <journal_schema>[ extra…]"
// (spec §7.1, §8: extra trailing fields allowed). A READY naming another tree is not a
// READY for this launch.
check_ready_line :: proc(line: string, tree: string) -> bool {
	fields := strings.fields(line, context.temp_allocator)
	if len(fields) < 4 || fields[0] != "READY" || fields[1] != tree do return false
	return is_decimal(fields[2]) && is_decimal(fields[3])
}

// Ready_Buffer accumulates bytes from the READY pipe until the first LF.
Ready_Buffer :: struct {
	buf: [256]byte,
	n:   int,
	eof: bool,
}

ready_buffer_line :: proc(b: ^Ready_Buffer) -> (line: string, ok: bool) {
	for i in 0 ..< b.n {
		if b.buf[i] == '\n' do return string(b.buf[:i]), true
	}
	return
}

// ---- stop request file (cross-session stop, T9 review carry-over (a)) ----

STOP_REQUEST_FILE :: "launcher-stop.request"

stop_request_path :: proc(l: ^Launcher) -> string {
	return join(l.cfg.instance_root, "supervisor", STOP_REQUEST_FILE)
}

// read_stop_request returns requested_at when the file exists and names this instance.
read_stop_request :: proc(l: ^Launcher) -> (requested_at: i64, present: bool, matches: bool) {
	path := stop_request_path(l)
	if !os.exists(path) do return
	present = true
	data, ok := read_small_file(path, context.temp_allocator)
	if !ok do return
	value, err := json.parse(data, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil do return
	obj, is_obj := json_object(value)
	if !is_obj do return
	id, has_id := json_string(obj, "instance_id")
	at, has_at := json_int(obj, "requested_at")
	if !has_id || !has_at || id != l.instance.instance_id do return
	return at, true, true
}

// discard_stale_stop_request removes a request older than this launcher, so a request
// left behind by a crashed caller can never stop a later launcher.
discard_stale_stop_request :: proc(l: ^Launcher) {
	at, present, matches := read_stop_request(l)
	if present && (!matches || at < l.started_unix) {
		log("discarding stale stop request")
		os.remove(stop_request_path(l))
	}
}

@(private)
stop_poll_counter: int

// stop_requested: OS stop (signal / event / session end) or a stop-request file
// written after this launcher started.
stop_requested :: proc(l: ^Launcher) -> bool {
	if platform_stop_signaled(l) do return true
	stop_poll_counter += 1
	if stop_poll_counter % 5 != 0 do return false
	at, present, matches := read_stop_request(l)
	if present && matches && at >= l.started_unix {
		log("stop requested through %s", STOP_REQUEST_FILE)
		os.remove(stop_request_path(l))
		platform_note_stop(l)
		return true
	}
	return false
}

// ---- launcher-status.json (diagnostics only, spec §7.1) ----

write_status :: proc(l: ^Launcher, state, tree: string, mode: Launch_Mode, reason: string) {
	b := strings.builder_make(context.temp_allocator)
	q :: proc(b: ^strings.Builder, s: string) {
		strings.write_byte(b, '"')
		for c in transmute([]byte)s {
			switch c {
			case '"', '\\':
				strings.write_byte(b, '\\')
				strings.write_byte(b, c)
			case 0 ..< 0x20:
				fmt.sbprintf(b, "\\u%04x", c)
			case:
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '"')
	}
	fmt.sbprintf(&b, "{{\"schema\":1,\"abi\":%d,\"pid\":%d,\"started_at\":%d,\"at\":%d,\"state\":", ABI, os.get_pid(), l.started_unix, time.time_to_unix(time.now()))
	q(&b, state)
	strings.write_string(&b, ",\"tree\":")
	q(&b, tree)
	fmt.sbprintf(&b, ",\"mode\":\"%s\",\"reason\":", "fallback" if mode == .Fallback else "normal")
	q(&b, reason)
	strings.write_string(&b, ",\"decision\":")
	q(&b, l.last_decision)
	fmt.sbprintf(&b, ",\"fallback\":%v,\"crash_count\":%d,\"last_exit\":", l.fallback_flag, l.crash_count)
	if l.last_exit.at == 0 {
		strings.write_string(&b, "null")
	} else {
		strings.write_string(&b, "{\"tree\":")
		q(&b, l.last_exit.tree)
		fmt.sbprintf(&b, ",\"mode\":\"%s\",\"code\":%d,\"signal\":%d,\"reason\":", "fallback" if l.last_exit.mode == .Fallback else "normal", l.last_exit.code, l.last_exit.signal)
		q(&b, l.last_exit.reason)
		fmt.sbprintf(&b, ",\"at\":%d}}", l.last_exit.at)
	}
	strings.write_string(&b, "}\n")
	path := join(l.cfg.instance_root, "launcher-status.json")
	tmp := fmt.tprintf("%s.tmp-%d", path, os.get_pid())
	if !write_file_synced(tmp, strings.to_string(b)) {
		os.remove(tmp)
		return
	}
	if !replace_file(tmp, path) do os.remove(tmp)
}

write_file_synced :: proc(path, data: string) -> bool {
	f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if err != nil do return false
	defer os.close(f)
	if _, werr := os.write_string(f, data); werr != nil do return false
	return os.sync(f) == nil
}
