package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "odin_test:lib/http_client"

// Bridge-side task scheduler: the "heavy lifting" half of task auto-promotion +
// auto-nudge. The Hub stays lean and exposes a compact actionable-task read
// (GET /api/v1/bridge/actionable-tasks) plus its existing mutation-path
// promotion. The Bridge polls that read once per tick and, for tasks whose
// target is a local instance, decides nudges and wakes agents directly (tmux +
// wrapper push) with zero extra Hub round-trips.
//
// Timing model: staleness is measured from when THIS bridge first observed a
// task in its current status (not the Hub's updated_at), which avoids hub/bridge
// clock skew and keeps all timing decisions local. Cooldown and wake coalescing
// are likewise in-memory per bridge.

BRIDGE_NUDGE_DEFAULT_INTERVAL_S :: 60
BRIDGE_NUDGE_DEFAULT_READY_S :: 300
BRIDGE_NUDGE_DEFAULT_REVIEW_S :: 300
BRIDGE_NUDGE_DEFAULT_WORKING_S :: 900
BRIDGE_NUDGE_DEFAULT_COOLDOWN_S :: 300
BRIDGE_NUDGE_DEFAULT_GRACE_S :: 30
BRIDGE_WAKE_COALESCE_MS :: i64(30_000)

Bridge_Nudge_Config :: struct {
	// enabled gates only the auto-NUDGE path (re-pinging stale actionable tasks).
	// The promotion-wake path (ensuring a queued task's assignee is running) is a
	// safety net that always runs while the sweep thread is active, independent of
	// this flag, so default-off config still picks up queued work.
	enabled:              bool,
	interval_seconds:     int,
	ready_after_seconds:  int,
	review_after_seconds: int,
	working_stale_after_seconds: int,
	cooldown_seconds:     int,
	grace_seconds:        int,
}

// Bridge_Task_Observation tracks per-task local timing state across ticks.
Bridge_Task_Observation :: struct {
	task_id:            string,
	status:             string,
	target_instance_id: string,
	first_seen_unix_ms: i64, // when this bridge first saw task in this status
	last_nudge_unix_ms: i64, // last nudge sent for this (task,target)
}

bridge_task_sched_mutex: sync.Mutex
bridge_task_observations: [dynamic]Bridge_Task_Observation
bridge_agent_wake: map[string]i64 // agent_instance_id -> last wake unix ms
bridge_nudge_config: Bridge_Nudge_Config

bridge_task_scheduler_init :: proc() {
	bridge_task_sched_mutex = sync.Mutex{}
	bridge_task_observations = make([dynamic]Bridge_Task_Observation)
	bridge_agent_wake = make(map[string]i64)
}

// bridge_task_scheduler_default_config returns the built-in defaults
// (disabled). Real config wiring can override these from the loaded config.
bridge_task_scheduler_default_config :: proc() -> Bridge_Nudge_Config {
	return Bridge_Nudge_Config{
		enabled                     = false,
		interval_seconds            = BRIDGE_NUDGE_DEFAULT_INTERVAL_S,
		ready_after_seconds         = BRIDGE_NUDGE_DEFAULT_READY_S,
		review_after_seconds        = BRIDGE_NUDGE_DEFAULT_REVIEW_S,
		working_stale_after_seconds = BRIDGE_NUDGE_DEFAULT_WORKING_S,
		cooldown_seconds            = BRIDGE_NUDGE_DEFAULT_COOLDOWN_S,
		grace_seconds               = BRIDGE_NUDGE_DEFAULT_GRACE_S,
	}
}

// bridge_task_scheduler_configure copies nudge knobs from the loaded bridge
// config into the scheduler's runtime config, applying defaults for any unset
// (zero) values so an enabled-but-sparse config still behaves sanely.
bridge_task_scheduler_configure :: proc() {
	cfg := bridge_task_scheduler_default_config()
	cfg.enabled = bridge_config.nudge_enabled
	if bridge_config.nudge_interval_seconds > 0 do cfg.interval_seconds = bridge_config.nudge_interval_seconds
	if bridge_config.nudge_ready_after_seconds > 0 do cfg.ready_after_seconds = bridge_config.nudge_ready_after_seconds
	if bridge_config.nudge_review_after_seconds > 0 do cfg.review_after_seconds = bridge_config.nudge_review_after_seconds
	if bridge_config.nudge_working_stale_after_seconds > 0 do cfg.working_stale_after_seconds = bridge_config.nudge_working_stale_after_seconds
	if bridge_config.nudge_cooldown_seconds > 0 do cfg.cooldown_seconds = bridge_config.nudge_cooldown_seconds
	if bridge_config.nudge_restart_grace_seconds >= 0 do cfg.grace_seconds = bridge_config.nudge_restart_grace_seconds
	bridge_nudge_config = cfg
}

bridge_task_scheduler_start :: proc() {
	bridge_task_scheduler_init()
	// The sweep runs whenever the bridge has hub connectivity, so the
	// promotion-wake safety net is active even when auto-nudge is disabled. The
	// nudge path inside the tick is separately gated by bridge_nudge_config.enabled.
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return
	thread.run(bridge_task_scheduler_worker)
}

bridge_task_scheduler_worker :: proc() {
	grace := bridge_nudge_config.grace_seconds
	if grace < 0 do grace = 0
	if grace > 0 do time.sleep(time.Duration(grace) * time.Second)
	for {
		bridge_task_scheduler_tick()
		interval := bridge_nudge_config.interval_seconds
		if interval <= 0 do interval = BRIDGE_NUDGE_DEFAULT_INTERVAL_S
		time.sleep(time.Duration(interval) * time.Second)
	}
}

// bridge_task_scheduler_tick performs one sweep: fetch actionable tasks, then
// for each locally-targeted task decide promotion-wake / nudge. Returns the
// number of actions taken (nudges delivered/queued + wakes requested).
bridge_task_scheduler_tick :: proc() -> int {
	body, ok := bridge_task_fetch_actionable()
	if !ok do return 0
	actions := 0
	now := bridge_runtime_now_ms()

	tasks_arr, has_tasks := bridge_provider_json_extract_array(body, "tasks")
	if !has_tasks do return 0
	objects := bridge_provider_json_top_level_objects(tasks_arr)
	defer delete(objects)

	// Track which task_ids we saw this tick to prune stale observations.
	seen := make(map[string]bool)
	defer delete(seen)

	for obj in objects {
		task_id := bridge_provider_json_extract_string(obj, "task_id", "")
		status := bridge_provider_json_extract_string(obj, "status", "")
		target := bridge_provider_json_extract_string(obj, "target_instance_id", "")
		deps_ok := strings.contains(obj, "\"deps_satisfied\":true")
		if task_id == "" || target == "" do continue
		seen[task_id] = true

		first_seen := bridge_task_observe(task_id, status, target, now)

		// Promotion-wake: an Assigned task whose deps are satisfied should be
		// worked. If the local assignee is not live, wake it (coalesced). The Hub
		// performs the durable status promotion on its own mutation path; here we
		// only ensure the agent is running so it can pick up the work.
		if status == "assigned" && deps_ok {
			if bridge_task_wake_if_needed(target, now) do actions += 1
			continue
		}

		// Nudge: stale actionable task past threshold + cooldown.
		last_nudge := bridge_task_last_nudge(task_id, target)
		if !bridge_task_should_nudge(bridge_nudge_config, status, first_seen, last_nudge, now) do continue

		if bridge_task_deliver_nudge(task_id, status, target, now) {
			bridge_task_mark_nudged(task_id, target, now)
			actions += 1
			fmt.printfln("SCHED_NUDGE ts=%d task=%s status=%s target=%s stale_ms=%d", now, task_id, status, target, now - first_seen)
		}
	}

	bridge_task_prune_unseen(seen)
	return actions
}

bridge_task_threshold_seconds :: proc(status: string) -> int {
	return bridge_task_threshold_seconds_cfg(bridge_nudge_config, status)
}

// bridge_task_threshold_seconds_cfg is the pure form (config passed explicitly)
// so it can be unit-tested without touching global scheduler state.
bridge_task_threshold_seconds_cfg :: proc(cfg: Bridge_Nudge_Config, status: string) -> int {
	switch status {
	case "assigned":            return cfg.ready_after_seconds
	case "in_progress":         return cfg.working_stale_after_seconds
	case "in_validation":       return cfg.review_after_seconds
	case "validated_not_good":  return cfg.ready_after_seconds
	case:                       return 0
	}
}

// bridge_task_should_nudge is the pure nudge gate: given the config, the task
// status, the timestamp this bridge first saw the task in this status, the last
// nudge time for the target, and now, decide whether to nudge. Mirrors the Hub
// evaluate_nudge decision but keyed on bridge-local observation time.
bridge_task_should_nudge :: proc(cfg: Bridge_Nudge_Config, status: string, first_seen_ms, last_nudge_ms, now_ms: i64) -> bool {
	if !cfg.enabled do return false
	threshold_ms := i64(bridge_task_threshold_seconds_cfg(cfg, status)) * 1000
	if threshold_ms <= 0 do return false
	if first_seen_ms <= 0 do return false
	if now_ms - first_seen_ms < threshold_ms do return false
	cooldown_ms := i64(cfg.cooldown_seconds) * 1000
	if cooldown_ms <= 0 do cooldown_ms = i64(BRIDGE_NUDGE_DEFAULT_COOLDOWN_S) * 1000
	if last_nudge_ms > 0 && now_ms - last_nudge_ms < cooldown_ms do return false
	return true
}

bridge_task_fetch_actionable :: proc() -> (string, bool) {
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", bridge_config.bridge_token})}}
	resp, ok := http.request_with_headers_timeout("GET", bridge_config.daemon_url, "/api/v1/bridge/actionable-tasks", "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok || resp.status != 200 do return "", false
	return resp.body, true
}

// bridge_task_observe records/updates the observation for a task and returns the
// first_seen timestamp for its CURRENT status (reset when status changes).
bridge_task_observe :: proc(task_id, status, target: string, now: i64) -> i64 {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for i in 0..<len(bridge_task_observations) {
		o := &bridge_task_observations[i]
		if o.task_id != task_id do continue
		if o.status != status {
			o.status = strings.clone(status)
			o.target_instance_id = strings.clone(target)
			o.first_seen_unix_ms = now
			o.last_nudge_unix_ms = 0
		}
		return o.first_seen_unix_ms
	}
	append(&bridge_task_observations, Bridge_Task_Observation{
		task_id = strings.clone(task_id), status = strings.clone(status),
		target_instance_id = strings.clone(target), first_seen_unix_ms = now,
	})
	return now
}

bridge_task_last_nudge :: proc(task_id, target: string) -> i64 {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for o in bridge_task_observations { if o.task_id == task_id && o.target_instance_id == target do return o.last_nudge_unix_ms }
	return 0
}

bridge_task_mark_nudged :: proc(task_id, target: string, now: i64) {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for i in 0..<len(bridge_task_observations) {
		o := &bridge_task_observations[i]
		if o.task_id == task_id && o.target_instance_id == target { o.last_nudge_unix_ms = now; return }
	}
}

bridge_task_prune_unseen :: proc(seen: map[string]bool) {
	sync.mutex_lock(&bridge_task_sched_mutex)
	defer sync.mutex_unlock(&bridge_task_sched_mutex)
	for i := len(bridge_task_observations) - 1; i >= 0; i -= 1 {
		if !seen[bridge_task_observations[i].task_id] {
			ordered_remove(&bridge_task_observations, i)
		}
	}
}

// bridge_task_status_notify_wake_local wakes a non-live target in response to a
// task_status_changed_notify (including the reconnect-replay orphan path). The
// Hub routes each notify ONLY to the bridge that hosts the target instance, so a
// target that arrives here is authoritative — we must not gate on the bridge's
// in-memory runtime registry, which is empty right after a bridge restart (the
// exact orphan-recovery case). We therefore trust the Hub's routing and attempt
// the wake directly; the launch path itself validates whether the instance can
// run locally (provider/tmux). Wakes remain coalesced within
// BRIDGE_WAKE_COALESCE_MS. Returns true when a wake was requested.
bridge_task_status_notify_wake_local :: proc(instance_id: string) -> bool {
	return bridge_task_wake_if_needed(instance_id, bridge_runtime_now_ms())
}

// bridge_task_wake_if_needed wakes a local instance if it is not currently live,
// coalescing wakes within BRIDGE_WAKE_COALESCE_MS. Returns true if a wake was
// requested.
bridge_task_wake_if_needed :: proc(instance_id: string, now: i64) -> bool {
	inst, found := bridge_runtime_instance_snapshot(instance_id)
	if found && bridge_runtime_status_active(inst.runtime_status) do return false

	sync.mutex_lock(&bridge_task_sched_mutex)
	last, has := bridge_agent_wake[instance_id]
	if has && now - last < BRIDGE_WAKE_COALESCE_MS {
		sync.mutex_unlock(&bridge_task_sched_mutex)
		return false
	}
	bridge_agent_wake[instance_id] = now
	sync.mutex_unlock(&bridge_task_sched_mutex)

	// Reuse the same launch path as a hub launch_agent command; a synthetic
	// command_id keeps the launch idempotency/caching machinery happy.
	command_id := fmt.tprintf("sched_wake_%s_%d", instance_id, now)
	command_json := strings.concatenate({"{\"type\":\"launch_agent\",\"command_id\":\"", command_id, "\",\"agent_instance_id\":\"", instance_id, "\"}"})
	ok, detail := bridge_runtime_launch_agent(command_id, command_json)
	if !ok do fmt.println("bridge scheduler wake failed", instance_id, detail)
	return ok
}

// bridge_task_deliver_nudge pushes a nudge to the local wrapper if live. If the
// wrapper is not connected, it wakes the agent (coalesced) so it can pick up the
// task on boot; the durable state already lives in the Hub.
bridge_task_deliver_nudge :: proc(task_id, status, target: string, now: i64) -> bool {
	payload := strings.concatenate({
		"{\"type\":\"notify_task_nudge\",\"origin\":\"scheduled\",\"task_id\":\"", task_id,
		"\",\"target_instance_id\":\"", target,
		"\",\"task_status\":\"", status,
		"\",\"message\":\"Task ", task_id, " needs attention (", status, ")\"}",
	})
	if bridge_wrapper_push_task_nudge(target, payload) do return true
	// Wrapper not live: ensure the agent is running so it sees the work on boot.
	return bridge_task_wake_if_needed(target, now)
}
