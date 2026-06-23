package main

import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"
import cfg_lib "odin_test:lib/config"

task_nudge_cfg:               cfg_lib.Daemon_Config
task_nudge_scheduler_started: bool

task_nudge_scheduler_start :: proc(cfg: cfg_lib.Daemon_Config) {
	task_nudge_cfg = cfg
	if !cfg.nudge_enabled do return
	if task_nudge_scheduler_started do return
	task_nudge_scheduler_started = true
	thread.run(task_nudge_scheduler_worker)
}

task_nudge_scheduler_worker :: proc() {
	grace := task_nudge_cfg.nudge_restart_grace_seconds
	if grace < 0 do grace = 0
	if grace > 0 do time.sleep(time.Duration(grace) * time.Second)
	for {
		task_nudge_scheduler_tick()
		interval := task_nudge_cfg.nudge_interval_seconds
		if interval <= 0 do interval = 60
		time.sleep(time.Duration(interval) * time.Second)
	}
}

task_nudge_scheduler_tick :: proc() -> int {
	if !task_nudge_cfg.nudge_enabled do return 0
	now     := router_now_unix_ms()
	changed := 0
	for i in 0..<task_state_count {
		state     := task_states[i]
		threshold := task_nudge_threshold_seconds(state.status)
		if threshold <= 0 do continue
		if state.updated_at_unix_ms == 0 do continue
		if now - state.updated_at_unix_ms < i64(threshold) * 1000 do continue
		target := task_nudge_target_for_status(state, state.status)
		last   := task_last_nudge_unix_ms(state.task_id, target)
		cooldown := task_nudge_cfg.nudge_cooldown_seconds
		if cooldown <= 0 do cooldown = 300
		if last > 0 && now - last < i64(cooldown) * 1000 do continue
		body := task_scheduled_nudge_body(state, target)
		kind := Task_Event_Kind.Task_Nudged
		if target == "" || !registry_agent_live(target) {
			kind = .Task_Nudge_Failed
			if target == "" {
				body = strings.concatenate({body, " reason=no_target"})
			} else {
				body = strings.concatenate({body, " reason=target_not_live"})
			}
		}
		event := Task_Event{
			kind                     = kind,
			task_id                  = state.task_id,
			chain_id                 = state.chain_id,
			status                   = task_status_to_string(state.status),
			body                     = body,
			agent_instance_id        = target,
			author_agent_instance_id = "task-nudge-scheduler",
		}
		if task_store_append_event(event) {
			if kind == .Task_Nudged do task_notify_event(event)
			changed += 1
		}
	}
	return changed
}

task_nudge_threshold_seconds :: proc(status: Task_Status) -> int {
	#partial switch status {
	case .Ready:
		return task_nudge_cfg.nudge_ready_after_seconds
	case .Review_Ready:
		return task_nudge_cfg.nudge_review_after_seconds
	case .In_Progress:
		return task_nudge_cfg.nudge_working_stale_after_seconds
	case:
		return 0
	}
}

task_last_nudge_unix_ms :: proc(task_id, target: string) -> i64 {
	last: i64
	for i in 0..<task_event_count {
		event := task_events[i]
		if event.task_id != task_id do continue
		if event.kind != .Task_Nudged && event.kind != .Task_Nudge_Failed do continue
		if target != "" && event.agent_instance_id != target do continue
		if event.created_unix_ms > last do last = event.created_unix_ms
	}
	return last
}

task_scheduled_nudge_body :: proc(state: Task_State, target: string) -> string {
	delivery := "ws_fallback"
	if task_nudge_cfg.nudge_send_escape_prefix do delivery = "escape_prefixed_pane_or_ws"
	action := "please continue work or move to blocked"
	#partial switch state.status {
	case .Ready:
		action = "task is ready to be worked on"
	case .Review_Ready:
		action = "waiting on your review"
	case .In_Progress:
		action = "please continue work or move to blocked"
	case:
		break
	}
	unresolved := task_unresolved_comments(state.task_id)
	defer delete(unresolved)
	b := strings.builder_make()
	strings.write_string(&b, fmt.tprintf("Task %s: %s. status=%s delivery=%s target=%s", state.task_id, action, task_status_to_string(state.status), delivery, target))
	if len(unresolved) > 0 {
		strings.write_string(&b, fmt.tprintf(" unresolved_comments=%d", len(unresolved)))
		limit := len(unresolved)
		if limit > 3 do limit = 3
		for i in 0..<limit {
			c := unresolved[i]
			snippet := c.body
			if len(snippet) > 80 do snippet = snippet[:80]
			strings.write_string(&b, fmt.tprintf(" [%s: %s]", c.author_agent_instance_id, snippet))
		}
	}
	return strings.to_string(b)
}

task_nudge_delivery_method :: proc(body: string) -> string {
	if strings.index(body, "delivery=escape_prefixed_pane_or_ws") >= 0 do return "escape_prefixed_pane_or_ws"
	if strings.index(body, "delivery=ws_fallback") >= 0 do return "ws_fallback"
	return "ws"
}
