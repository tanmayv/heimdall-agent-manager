package main

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "odin_test:lib/http_client"

// Bridge prompt scheduler engine (SP-3).
//
// Mirroring task_scheduler.odin:
// 1. Watches schedules_version on bridge_heartbeat_ack.
// 2. On version change (or initial start or 24h daily reconcile), issues a conditional
//    GET /api/v1/bridge/scheduled-prompts (If-None-Match ETag) scoped to this bridge's instances.
// 3. Maintains an in-memory queue of prompt schedules and ticks locally.
// 4. At target_run_at: evaluates target instance readiness, wakes/launches via existing
//    runtime plumbing if stopped and awaits ready, then POSTs to .../execute.
// 5. Implements lease recovery: reclaims in_flight prompts older than lease window back to active.

PROMPT_SCHEDULER_TICK_INTERVAL_S :: 1
PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS :: i64(60_000)
PROMPT_SCHEDULER_RECONCILE_INTERVAL_MS :: i64(86_400_000) // 24 hours

Prompt_Queue_Item :: struct {
	id:                 string,
	target_instance_id: string,
	prompt_text:        string,
	target_run_at:      string,
	target_run_at_ms:   i64,
	interval:           string,
	interval_seconds:   int,
	state:              string,
	in_flight:          bool,
	leased_at_ms:       i64,
}

Bridge_Prompt_Scheduler_State :: struct {
	mutex:                    sync.Mutex,
	queue:                    [dynamic]Prompt_Queue_Item,
	known_schedules_version:  int,
	synced_schedules_version: int,
	last_etag:                string,
	last_full_reconcile_ms:   i64,
	running:                  bool,
}

bridge_prompt_sched_state: Bridge_Prompt_Scheduler_State

// --- Pure timing / claim / advance procedures ---

prompt_scheduler_days_from_civil :: proc(y_in, m, d: int) -> int {
	y := y_in
	if m <= 2 do y -= 1
	era := (y if y >= 0 else y - 399) / 400
	yoe := y - era * 400
	mp := (m + 9) %% 12
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

// Parses hub UTC RFC3339 timestamp (YYYY-MM-DDTHH:MM:SSZ) to unix milliseconds.
prompt_scheduler_parse_rfc3339_ms :: proc(s: string) -> (i64, bool) {
	t := strings.trim_space(s)
	if len(t) < 20 do return 0, false
	if t[4] != '-' || t[7] != '-' || t[10] != 'T' || t[13] != ':' || t[16] != ':' do return 0, false
	parse2 :: proc(str: string) -> (int, bool) {
		if len(str) < 2 do return 0, false
		a := int(str[0]) - '0'; b := int(str[1]) - '0'
		if a < 0 || a > 9 || b < 0 || b > 9 do return 0, false
		return a*10 + b, true
	}
	parse4 :: proc(str: string) -> (int, bool) {
		hi, ok1 := parse2(str[0:2]); lo, ok2 := parse2(str[2:4])
		if !ok1 || !ok2 do return 0, false
		return hi*100 + lo, true
	}
	year, y_ok := parse4(t[0:4])
	month, mo_ok := parse2(t[5:7])
	day, d_ok := parse2(t[8:10])
	hour, h_ok := parse2(t[11:13])
	minute, mi_ok := parse2(t[14:16])
	second, s_ok := parse2(t[17:19])
	if !(y_ok && mo_ok && d_ok && h_ok && mi_ok && s_ok) do return 0, false
	if month < 1 || month > 12 do return 0, false
	days := prompt_scheduler_days_from_civil(year, month, day)
	total_secs := i64(days) * 86400 + i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	return total_secs * 1000, true
}

prompt_scheduler_parse_interval_seconds :: proc(interval: string) -> int {
	s := strings.trim_space(interval)
	if len(s) == 0 do return 0
	unit := s[len(s)-1]
	val_str := s[:len(s)-1]
	val, ok := strconv.parse_int(val_str)
	if !ok || val <= 0 do return 0
	switch unit {
	case 's': return val
	case 'm': return val * 60
	case 'h': return val * 3600
	case 'd': return val * 86400
	case:
		num, num_ok := strconv.parse_int(s)
		if num_ok && num > 0 do return num
		return 0
	}
}

prompt_scheduler_is_due :: proc(target_run_at_ms, now_ms: i64) -> bool {
	return target_run_at_ms > 0 && now_ms >= target_run_at_ms
}

prompt_scheduler_can_claim :: proc(item: Prompt_Queue_Item, now_ms: i64, lease_window_ms: i64 = PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) -> bool {
	if item.state == "completed" do return false
	if !prompt_scheduler_is_due(item.target_run_at_ms, now_ms) do return false
	if !item.in_flight do return true
	// In-flight: claimable only if lease has expired
	if lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) do return true
	return false
}

prompt_scheduler_claim :: proc(item: ^Prompt_Queue_Item, now_ms: i64) {
	if item == nil do return
	item.in_flight = true
	item.leased_at_ms = now_ms
	item.state = "in_flight"
}

prompt_scheduler_recover_lease :: proc(item: ^Prompt_Queue_Item, now_ms: i64, lease_window_ms: i64 = PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) -> bool {
	if item == nil do return false
	if item.in_flight && lease_window_ms > 0 && item.leased_at_ms > 0 && (now_ms - item.leased_at_ms >= lease_window_ms) {
		item.in_flight = false
		item.state = "active"
		return true
	}
	return false
}

prompt_scheduler_advance_ms :: proc(target_run_at_ms: i64, interval_seconds: int, now_ms: i64) -> (next_run_ms: i64, completed: bool) {
	if interval_seconds <= 0 {
		return target_run_at_ms, true
	}
	interval_ms := i64(interval_seconds) * 1000
	next := target_run_at_ms + interval_ms
	// On missed intervals, fire once and resync to next future slot
	for next <= now_ms {
		next += interval_ms
	}
	return next, false
}

prompt_queue_item_free :: proc(item: ^Prompt_Queue_Item) {
	if item == nil do return
	delete(item.id)
	delete(item.target_instance_id)
	delete(item.prompt_text)
	delete(item.target_run_at)
	delete(item.interval)
	delete(item.state)
}

// --- Bridge runtime scheduling engine ---

bridge_prompt_scheduler_init :: proc() {
	bridge_prompt_sched_state = Bridge_Prompt_Scheduler_State{
		mutex                    = sync.Mutex{},
		queue                    = make([dynamic]Prompt_Queue_Item),
		known_schedules_version  = 0,
		synced_schedules_version = -1,
		last_etag                = "",
		last_full_reconcile_ms   = 0,
		running                  = false,
	}
}

bridge_prompt_scheduler_start :: proc() {
	bridge_prompt_scheduler_init()
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return
	bridge_prompt_sched_state.running = true
	thread.run(bridge_prompt_scheduler_worker)
}

bridge_prompt_scheduler_worker :: proc() {
	for bridge_prompt_sched_state.running {
		bridge_prompt_scheduler_tick()
		time.sleep(time.Duration(PROMPT_SCHEDULER_TICK_INTERVAL_S) * time.Second)
	}
}

bridge_prompt_scheduler_notify_version :: proc(version: int) {
	if version <= 0 do return
	sync.mutex_lock(&bridge_prompt_sched_state.mutex)
	defer sync.mutex_unlock(&bridge_prompt_sched_state.mutex)
	if version > bridge_prompt_sched_state.known_schedules_version {
		bridge_prompt_sched_state.known_schedules_version = version
	}
}

bridge_prompt_scheduler_sync :: proc() -> bool {
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" do return false
	now_ms := bridge_runtime_now_ms()

	sync.mutex_lock(&bridge_prompt_sched_state.mutex)
	last_etag := bridge_prompt_sched_state.last_etag
	version_to_sync := bridge_prompt_sched_state.known_schedules_version
	sync.mutex_unlock(&bridge_prompt_sched_state.mutex)

	headers := make([dynamic]http.Header)
	defer delete(headers)
	auth_header := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth_header)
	append(&headers, http.Header{name = "Authorization", value = auth_header})
	if last_etag != "" {
		append(&headers, http.Header{name = "If-None-Match", value = last_etag})
	}

	resp, ok := http.request_with_headers_timeout("GET", bridge_config.daemon_url, "/api/v1/bridge/scheduled-prompts", "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return false
	defer delete(resp.body)

	if resp.status == 304 {
		sync.mutex_lock(&bridge_prompt_sched_state.mutex)
		bridge_prompt_sched_state.synced_schedules_version = version_to_sync
		bridge_prompt_sched_state.last_full_reconcile_ms = now_ms
		sync.mutex_unlock(&bridge_prompt_sched_state.mutex)
		return true
	}

	if resp.status != 200 do return false

	data_arr, has_data := bridge_provider_json_extract_array(resp.body, "data")
	if !has_data do return false

	objects := bridge_provider_json_top_level_objects(data_arr)
	defer {
		for obj in objects do delete(obj)
		delete(objects)
	}

	sync.mutex_lock(&bridge_prompt_sched_state.mutex)
	defer sync.mutex_unlock(&bridge_prompt_sched_state.mutex)

	seen := make(map[string]bool)
	defer delete(seen)

	for obj in objects {
		id := extract_json_string(obj, "id", "")
		if id == "" do continue
		seen[id] = true

		target := extract_json_string(obj, "target_instance_id", "")
		prompt := extract_json_string(obj, "prompt_text", "")
		run_at := extract_json_string(obj, "target_run_at", "")
		interval := extract_json_string(obj, "interval", "")
		state := extract_json_string(obj, "state", "active")
		in_flight := strings.contains(obj, "\"in_flight\":true")
		leased_at := extract_json_string(obj, "leased_at", "")
		run_at_ms, _ := prompt_scheduler_parse_rfc3339_ms(run_at)
		leased_at_ms, _ := prompt_scheduler_parse_rfc3339_ms(leased_at)
		interval_secs := prompt_scheduler_parse_interval_seconds(interval)

		found_idx := -1
		for i in 0..<len(bridge_prompt_sched_state.queue) {
			if bridge_prompt_sched_state.queue[i].id == id {
				found_idx = i
				break
			}
		}

		if found_idx >= 0 {
			q := &bridge_prompt_sched_state.queue[found_idx]
			is_locally_in_flight := q.in_flight && (now_ms - q.leased_at_ms < PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS)
			prompt_queue_item_free(q)
			q.id = strings.clone(id)
			q.target_instance_id = strings.clone(target)
			q.prompt_text = strings.clone(prompt)
			q.target_run_at = strings.clone(run_at)
			q.target_run_at_ms = run_at_ms
			q.interval = strings.clone(interval)
			q.interval_seconds = interval_secs
			q.state = strings.clone(state)
			if is_locally_in_flight {
				q.in_flight = true
			} else {
				q.in_flight = in_flight
				q.leased_at_ms = leased_at_ms
			}
		} else {
			append(&bridge_prompt_sched_state.queue, Prompt_Queue_Item{
				id                 = strings.clone(id),
				target_instance_id = strings.clone(target),
				prompt_text        = strings.clone(prompt),
				target_run_at      = strings.clone(run_at),
				target_run_at_ms   = run_at_ms,
				interval           = strings.clone(interval),
				interval_seconds   = interval_secs,
				state              = strings.clone(state),
				in_flight          = in_flight,
				leased_at_ms       = leased_at_ms,
			})
		}
	}

	// Prune items deleted on Hub
	for i := len(bridge_prompt_sched_state.queue) - 1; i >= 0; i -= 1 {
		item_id := bridge_prompt_sched_state.queue[i].id
		if !seen[item_id] {
			prompt_queue_item_free(&bridge_prompt_sched_state.queue[i])
			ordered_remove(&bridge_prompt_sched_state.queue, i)
		}
	}

	bridge_prompt_sched_state.last_etag = fmt.tprintf("W/\"%d\"", version_to_sync)
	bridge_prompt_sched_state.synced_schedules_version = version_to_sync
	bridge_prompt_sched_state.last_full_reconcile_ms = now_ms

	return true
}

bridge_prompt_scheduler_update_from_execute_response :: proc(prompt_id, body: string) {
	data_obj, ok := bridge_provider_json_extract_object(body, "data")
	if !ok do return

	run_at := extract_json_string(data_obj, "target_run_at", "")
	state := extract_json_string(data_obj, "state", "")
	run_at_ms, _ := prompt_scheduler_parse_rfc3339_ms(run_at)

	sync.mutex_lock(&bridge_prompt_sched_state.mutex)
	defer sync.mutex_unlock(&bridge_prompt_sched_state.mutex)

	for i in 0..<len(bridge_prompt_sched_state.queue) {
		q := &bridge_prompt_sched_state.queue[i]
		if q.id == prompt_id {
			if state == "completed" {
				prompt_queue_item_free(q)
				ordered_remove(&bridge_prompt_sched_state.queue, i)
			} else {
				delete(q.target_run_at)
				q.target_run_at = strings.clone(run_at)
				q.target_run_at_ms = run_at_ms
				delete(q.state)
				q.state = strings.clone(state)
				q.in_flight = false
				q.leased_at_ms = 0
			}
			break
		}
	}
}

bridge_prompt_scheduler_execute :: proc(prompt_id: string) -> (bool, int, string) {
	if strings.trim_space(bridge_config.bridge_token) == "" || strings.trim_space(bridge_config.daemon_url) == "" {
		return false, 0, ""
	}
	path := fmt.tprintf("/api/v1/bridge/scheduled-prompts/%s/execute", prompt_id)
	auth_header := strings.concatenate({"Bearer ", bridge_config.bridge_token})
	defer delete(auth_header)
	headers := [?]http.Header{
		{name = "Authorization", value = auth_header},
	}
	resp, ok := http.request_with_headers_timeout("POST", bridge_config.daemon_url, path, "{}", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return false, 0, ""
	return resp.status == 200, resp.status, resp.body
}

bridge_prompt_scheduler_await_ready :: proc(instance_id: string, max_wait_ms: int = 5000) -> bool {
	deadline := bridge_runtime_now_ms() + i64(max_wait_ms)
	for bridge_runtime_now_ms() < deadline {
		inst, found := bridge_runtime_instance_snapshot(instance_id)
		if found && (inst.runtime_status == "running" || inst.runtime_status == "idle") {
			return true
		}
		time.sleep(200 * time.Millisecond)
	}
	inst, found := bridge_runtime_instance_snapshot(instance_id)
	return found && (inst.runtime_status == "running" || inst.runtime_status == "idle")
}

bridge_prompt_scheduler_tick :: proc() -> int {
	now_ms := bridge_runtime_now_ms()
	actions := 0

	// 1. Sync if version changed, uninitialized, or daily reconcile backstop reached
	sync_needed := false
	sync.mutex_lock(&bridge_prompt_sched_state.mutex)
	if bridge_prompt_sched_state.known_schedules_version != bridge_prompt_sched_state.synced_schedules_version ||
	   bridge_prompt_sched_state.synced_schedules_version < 0 ||
	   (bridge_prompt_sched_state.last_full_reconcile_ms > 0 && now_ms - bridge_prompt_sched_state.last_full_reconcile_ms >= PROMPT_SCHEDULER_RECONCILE_INTERVAL_MS) {
		sync_needed = true
	}
	sync.mutex_unlock(&bridge_prompt_sched_state.mutex)

	if sync_needed {
		bridge_prompt_scheduler_sync()
	}

	// 2. Lease recovery on in-flight items
	sync.mutex_lock(&bridge_prompt_sched_state.mutex)
	for i in 0..<len(bridge_prompt_sched_state.queue) {
		item := &bridge_prompt_sched_state.queue[i]
		if prompt_scheduler_recover_lease(item, now_ms, PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
			fmt.printfln("PROMPT_SCHED_LEASE_RECOVERY id=%s target=%s", item.id, item.target_instance_id)
		}
	}

	// Collect due items to evaluate
	due_items := make([dynamic]Prompt_Queue_Item)
	defer delete(due_items)
	for item in bridge_prompt_sched_state.queue {
		if prompt_scheduler_can_claim(item, now_ms, PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
			append(&due_items, item)
		}
	}
	sync.mutex_unlock(&bridge_prompt_sched_state.mutex)

	// 3. Process due items
	for due in due_items {
		inst, found := bridge_runtime_instance_snapshot(due.target_instance_id)
		is_ready := found && (inst.runtime_status == "running" || inst.runtime_status == "idle")

		if !is_ready {
			if !found || !bridge_runtime_status_active(inst.runtime_status) {
				bridge_task_wake_if_needed(due.target_instance_id, now_ms)
			}
			if bridge_prompt_scheduler_await_ready(due.target_instance_id, 3000) {
				is_ready = true
			}
		}

		if !is_ready {
			continue
		}

		sync.mutex_lock(&bridge_prompt_sched_state.mutex)
		claimed := false
		for i in 0..<len(bridge_prompt_sched_state.queue) {
			if bridge_prompt_sched_state.queue[i].id == due.id {
				if prompt_scheduler_can_claim(bridge_prompt_sched_state.queue[i], now_ms, PROMPT_SCHEDULER_DEFAULT_LEASE_WINDOW_MS) {
					prompt_scheduler_claim(&bridge_prompt_sched_state.queue[i], now_ms)
					claimed = true
				}
				break
			}
		}
		sync.mutex_unlock(&bridge_prompt_sched_state.mutex)

		if !claimed do continue

		ok, status, body := bridge_prompt_scheduler_execute(due.id)
		if ok {
			actions += 1
			bridge_prompt_scheduler_update_from_execute_response(due.id, body)
			delete(body)
		} else {
			if body != "" do delete(body)
			sync.mutex_lock(&bridge_prompt_sched_state.mutex)
			for i in 0..<len(bridge_prompt_sched_state.queue) {
				if bridge_prompt_sched_state.queue[i].id == due.id {
					bridge_prompt_sched_state.queue[i].in_flight = false
					if status == 409 {
						bridge_prompt_sched_state.synced_schedules_version = -1
					}
					break
				}
			}
			sync.mutex_unlock(&bridge_prompt_sched_state.mutex)
		}
	}

	return actions
}
