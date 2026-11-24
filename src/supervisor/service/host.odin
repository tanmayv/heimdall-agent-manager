package service

// The real engine.Host (spec §2, §2.1, §12, §14 health): starts the runtime from a release
// tree as a managed child, records it in procs.json, stops it through the T14 adapter
// (src/supervisor/runtimectl) and reaps survivors of a crashed predecessor (J0).
//
// Children: POSIX — each child leads its own process group (setpgid), Linux children also
// get PR_SET_PDEATHSIG; Windows — every child is created suspended, assigned to this
// supervisor's per-instance job object (KILL_ON_JOB_CLOSE, nested in the launcher's job)
// and resumed, so the whole runtime tree, agents included, dies with the supervisor.
//
// Health: Starting until the runtime's control endpoint (<data>/run/supervisor-control.json,
// written by ham-bridge, spec §12.2) names the runtime's pid and answers a request; Ready
// while it keeps answering; Exited once any child exited. Hub connection: the runtime's
// <state>/runtime-status.json (pid, connected, updated_at).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../engine"
import "../procs"
import "../runtimectl"

RUN_DIR :: "run"
CONTROL_FILE :: "supervisor-control.json"
RUNTIME_STATUS_FILE :: "runtime-status.json"
REAP_TERM_GRACE_MS :: 5_000 // J0: SIGTERM -> 5 s -> SIGKILL
REAP_TOTAL_MS :: 20_000 // J0: 20 s for the whole reap
STOP_BUDGET_MS :: 15_000 // §7.5: the supervisor's whole stop budget (launcher waits 20 s)
STOP_SESSION_GRACE_MS :: 4_000 // service stop: sessions' grace (activation stop: 10 s, §12)
STOP_TERM_GRACE_MS :: 2_000
STOP_WAIT_MS :: 6_000 // service stop: wait after SIGKILL / TerminateProcess (activation: 30 s)
#assert(STOP_SESSION_GRACE_MS + STOP_TERM_GRACE_MS + STOP_WAIT_MS < STOP_BUDGET_MS)
HUB_RECENT_S :: 300 // §14: `connected` within 5 min before gate_closed
STATUS_FRESH_S :: 90 // a runtime-status.json older than this is not "connected now"

// Child_Spec: one process to start from a tree. `exe` is a file under <tree>/bin/.
Child_Spec :: struct {
	role: string,
	exe:  string,
	args: []string,
}

// Spec_Proc builds the children of a tree (temp-allocated). Tests replace it.
Spec_Proc :: proc(h: ^Host_Ctx, tree: string) -> []Child_Spec

Running :: struct {
	rec:    Proc_Record,
	child:  Child, // platform handle
	exited: bool,
}

Host_Ctx :: struct {
	instance_root: string,
	state_root:    string,
	instance_id:   string,
	specs:         Spec_Proc,
	stop_flag:     proc() -> bool,
	// Pass every child a lifeline (POSIX fd 3 / Windows inherited handle, `--lifeline-fd`).
	lifeline:      bool,
	log:           proc(msg: string),
	rt:            runtimectl.Client,
	running:       [dynamic]Running,
	tree:          string,
	job:           Job,
	stop_fn:       Stop_Proc, // tests; nil = runtimectl.stop_children
}

host_init :: proc(h: ^Host_Ctx, instance_root, state_root, instance_id: string) {
	h.instance_root = strings.clone(instance_root)
	h.state_root = strings.clone(state_root)
	h.instance_id = strings.clone(instance_id)
	h.running = make([dynamic]Running)
	runtimectl.init(&h.rt, engine.join(instance_root, RUN_DIR, CONTROL_FILE))
	if h.specs == nil do h.specs = default_specs
}

host_destroy :: proc(h: ^Host_Ctx) {
	for &r in h.running do child_release(&r.child)
	delete(h.running)
	runtimectl.destroy(&h.rt)
	job_close(&h.job)
	delete(h.instance_root)
	delete(h.state_root)
	delete(h.instance_id)
	delete(h.tree)
}

hlog :: proc(h: ^Host_Ctx, format: string, args: ..any) {
	if h.log != nil do h.log(fmt.tprintf(format, ..args))
}

// engine_host: the engine.Host backed by `h` (gate hooks from runtimectl).
engine_host :: proc(h: ^Host_Ctx) -> engine.Host {
	eh := engine.Host {
		user = h,
		now = proc(u: rawptr) -> i64 {return time.time_to_unix(time.now())},
		reap = proc(u: rawptr) -> bool {return host_reap((^Host_Ctx)(u))},
		start_runtime = proc(u: rawptr, tree: string) -> bool {return host_start((^Host_Ctx)(u), tree)},
		stop_children = proc(u: rawptr, tree: string) -> bool {return host_stop((^Host_Ctx)(u))},
		health = proc(u: rawptr) -> engine.Health {return host_health((^Host_Ctx)(u))},
		hub_connected = proc(u: rawptr) -> bool {return host_hub((^Host_Ctx)(u), STATUS_FRESH_S)},
		hub_recently_connected = proc(u: rawptr) -> bool {return host_hub((^Host_Ctx)(u), HUB_RECENT_S)},
		stop_requested = proc(u: rawptr) -> bool {
			h := (^Host_Ctx)(u)
			return h.stop_flag != nil && h.stop_flag()
		},
	}
	runtimectl.install(&eh, &h.rt)
	return eh
}

// default_specs: the runtime as today's service runs it (src/lib/bridgesvc/render.odin
// service_args), from instance.json and <state>/ports.json. ham-bridge starts and owns its
// PTY host; both run inside this supervisor's job / are stopped with its sessions.
default_specs :: proc(h: ^Host_Ctx, tree: string) -> []Child_Spec {
	hub := ""
	if data, err := os.read_entire_file(engine.join(h.instance_root, "instance.json"), context.temp_allocator); err == nil {
		if v, perr := json.parse(data, .JSON, true, context.temp_allocator); perr == nil {
			if o, ok := v.(json.Object); ok {
				if s, sok := o["hub_url"].(json.String); sok do hub = string(s)
			}
		}
	}
	bridge_port, endpoint_port: i64 = 0, 0
	if data, err := os.read_entire_file(engine.join(h.state_root, "ports.json"), context.temp_allocator); err == nil {
		bridge_port, _ = json_int_field(data, "bridge_port")
		endpoint_port, _ = json_int_field(data, "local_endpoint_port")
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "--hub", hub, "--config", engine.join(h.state_root, "config.toml"),
		"--bridge-token-file", engine.join(h.state_root, "bridge-token"), "--data-dir", h.instance_root,
		"--bind-host", "127.0.0.1", "--local-run-dir", engine.join(h.instance_root, RUN_DIR))
	if bridge_port > 0 do append(&args, "--port", fmt.tprintf("%d", bridge_port))
	if endpoint_port > 0 do append(&args, "--local-endpoint-port", fmt.tprintf("%d", endpoint_port))
	out := make([]Child_Spec, 1, context.temp_allocator)
	out[0] = Child_Spec{role = "runtime", exe = "ham-bridge", args = args[:]}
	return out
}

tree_bin :: proc(h: ^Host_Ctx, tree, exe: string) -> string {
	name := strings.concatenate({exe, ".exe"}, context.temp_allocator) when ODIN_OS == .Windows else exe
	return engine.join(h.instance_root, "releases", tree, "bin", name)
}

@(private)
records :: proc(h: ^Host_Ctx) -> []Proc_Record {
	out := make([dynamic]Proc_Record, context.temp_allocator)
	for r in h.running do if !r.exited do append(&out, r.rec)
	return out[:]
}

// host_reap (J0, §2.1 layer 3): stop every live procs.json entry of a predecessor, wait
// until each is gone (20 s in total), then empty procs.json. false = a survivor.
host_reap :: proc(h: ^Host_Ctx) -> bool {
	list := read_procs(h.instance_root)
	if len(list) == 0 do return true
	targets := make([dynamic]procs.Target, context.temp_allocator)
	for r in list {
		if r.job != "" do job_terminate_by_name(r.job)
		append(&targets, procs.Target{id = r.id, group = r.group})
	}
	res := procs.stop(targets[:], REAP_TERM_GRACE_MS, REAP_TOTAL_MS - REAP_TERM_GRACE_MS)
	if res.survivors > 0 {
		hlog(h, "reap: %d recorded process(es) survived", res.survivors)
		return false
	}
	return write_procs(h.instance_root, nil) == nil
}

// host_start starts the children of `tree` and records each right after its spawn.
host_start :: proc(h: ^Host_Ctx, tree: string) -> bool {
	if !job_ensure(&h.job, h.instance_id) {
		hlog(h, "cannot create the instance job object")
		return false
	}
	delete(h.tree)
	h.tree = strings.clone(tree)
	for &r in h.running do child_release(&r.child)
	clear(&h.running)
	// Never start a runtime next to a recorded process that still runs (a survivor of a
	// failed stop: same credentials, report F5). Health then reports Exited; the idle
	// watcher's next stop attempt escalates (fatal stop_timeout -> exit 1 -> J0 reap).
	if n := live_recorded(h); n > 0 {
		hlog(h, "not starting %s: %d recorded process(es) from an earlier start still run", tree, n)
		append(&h.running, Running{exited = true})
		return false
	}
	_ = os.make_directory_all(engine.join(h.instance_root, RUN_DIR), engine.PRIVATE_DIR_PERMS)
	_ = os.make_directory_all(engine.join(h.instance_root, "logs"), engine.PRIVATE_DIR_PERMS)
	// A stale control file from the previous runtime must not count as this one ready.
	_ = os.remove(engine.join(h.instance_root, RUN_DIR, CONTROL_FILE))
	ok := true
	for spec in h.specs(h, tree) {
		exe := tree_bin(h, tree, spec.exe)
		log_path := engine.join(h.instance_root, "logs", fmt.tprintf("%s.log", spec.role))
		child, id, err := child_spawn(h, exe, spec.args, log_path)
		if err != "" {
			hlog(h, "start %s from %s: %s", spec.role, tree, err)
			ok = false
			break
		}
		append(&h.running, Running{rec = Proc_Record{id = id, group = ODIN_OS != .Windows, role = spec.role, tree = h.tree, job = job_name(&h.job)}, child = child})
		if werr := write_procs_merged(h.instance_root, records(h)); werr != nil {
			hlog(h, "procs.json: %s", engine.error_detail(werr))
		}
	}
	if !ok {
		_ = host_stop(h)
		// Leave one exited entry so health reports Exited and the engine judges it.
		append(&h.running, Running{exited = true})
		return false
	}
	return true
}

// live_recorded: procs.json entries whose (pid, start_time) still run.
live_recorded :: proc(h: ^Host_Ctx) -> int {
	n := 0
	for r in read_procs(h.instance_root) do if procs.running(procs.Target{id = r.id, group = r.group}) do n += 1
	return n
}

// Stop_Proc stops the recorded children (and the sessions the runtime reported); false =
// a survivor. Tests replace it; nil = runtimectl.stop_children with host_stop's budget.
Stop_Proc :: proc(h: ^Host_Ctx, recorded: []procs.Target) -> bool

// host_stop (§12 stopping, W7): the runtime's sessions get their grace, then every
// recorded process is stopped and waited for. procs.json then keeps exactly the recorded
// processes (children and sessions) that still run — never fewer — so a later start refuses
// to run beside them and the next supervisor's J0 reap can find them (§2.1 layer 3).
//
// Budget: the activation stop uses §12's 10 s session grace + 30 s wait. A service stop
// (§7.5, the launcher waits 20 s) uses STOP_SESSION_GRACE_MS + STOP_TERM_GRACE_MS +
// STOP_WAIT_MS = 4 + 2 + 6 s, inside STOP_BUDGET_MS (15 s) with room for the journal line
// and the child_wait below.
host_stop :: proc(h: ^Host_Ctx) -> bool {
	recorded := make([dynamic]procs.Target, context.temp_allocator)
	keep := make([dynamic]Proc_Record, context.temp_allocator)
	for r in h.running {
		if !r.exited && r.rec.id.pid > 0 {
			append(&recorded, procs.Target{id = r.rec.id, group = r.rec.group})
			append(&keep, r.rec)
		}
	}
	// Recorded survivors of an earlier start (a stop that failed before) are ours too.
	for r in read_procs(h.instance_root) {
		dup := false
		for k in keep do if k.id == r.id do dup = true
		if dup || !procs.running(procs.Target{id = r.id, group = r.group}) do continue
		append(&recorded, procs.Target{id = r.id, group = r.group})
		append(&keep, r)
	}
	for t in h.rt.sessions do append(&keep, Proc_Record{id = t.id, group = t.group, role = "session", tree = h.tree})
	ok: bool
	if h.stop_fn != nil {
		ok = h.stop_fn(h, recorded[:])
	} else if h.stop_flag != nil && h.stop_flag() {
		ok = runtimectl.stop_children(&h.rt, recorded[:], STOP_SESSION_GRACE_MS, STOP_TERM_GRACE_MS, STOP_WAIT_MS)
	} else {
		ok = runtimectl.stop_children(&h.rt, recorded[:])
	}
	// Collect exit statuses (procs never reaps) and close handles. A survivor's handle is
	// released too; its record stays in procs.json below.
	for &r in h.running {
		if !r.exited {
			child_wait(&r.child, 2_000 if ok else 0)
			if child_exited(&r.child) do r.exited = true
		}
		child_release(&r.child)
	}
	when ODIN_OS == .Windows {
		// Whatever the sessions started (node, tools) is in the job too.
		job_terminate(&h.job)
	}
	clear(&h.running)
	survivors := make([dynamic]Proc_Record, context.temp_allocator)
	for r in keep do if procs.running(procs.Target{id = r.id, group = r.group}) do append(&survivors, r)
	if len(survivors) > 0 {
		hlog(h, "stop: %d recorded process(es) survive; kept in procs.json", len(survivors))
		ok = false
	}
	_ = write_procs_merged(h.instance_root, survivors[:])
	return ok
}

host_health :: proc(h: ^Host_Ctx) -> engine.Health {
	if len(h.running) == 0 do return .Down
	runtime_pid := 0
	for &r in h.running {
		if !r.exited && child_exited(&r.child) do r.exited = true
		if r.exited do return .Exited
		if r.rec.role == "runtime" do runtime_pid = r.rec.id.pid
	}
	if control_pid(h) != runtime_pid || runtime_pid == 0 do return .Starting
	if _, ok := runtimectl.request(&h.rt, "supervisor.gate.count"); !ok do return .Starting
	return .Ready
}

// control_pid: the pid named by the runtime's control file (0 = none).
@(private)
control_pid :: proc(h: ^Host_Ctx) -> int {
	data, err := os.read_entire_file(h.rt.control_path, context.temp_allocator)
	if err != nil do return 0
	n, ok := json_int_field(data, "pid")
	return int(n) if ok else 0
}

// host_hub: runtime-status.json of this runtime says `connected`, updated within `fresh_s`.
host_hub :: proc(h: ^Host_Ctx, fresh_s: i64) -> bool {
	data, err := os.read_entire_file(engine.join(h.state_root, RUNTIME_STATUS_FILE), context.temp_allocator)
	if err != nil do return false
	v, perr := json.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil do return false
	o, ok := v.(json.Object)
	if !ok do return false
	pid, _ := o["pid"].(json.Integer)
	connected, _ := o["connected"].(json.Boolean)
	updated, _ := o["updated_at"].(json.Integer)
	mine := false
	for r in h.running do if r.rec.role == "runtime" && r.rec.id.pid == int(pid) do mine = true
	return mine && bool(connected) && time.time_to_unix(time.now()) - i64(updated) <= fresh_s
}
