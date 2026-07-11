package main

import "core:fmt"
import "core:strings"
import "core:thread"
import "core:time"
import "core:strconv"

scheduled_prompt_scheduler_started: bool
scheduled_prompt_scheduler_running: bool

scheduled_prompt_scheduler_start :: proc(data_dir: string) -> bool {
	if scheduled_prompt_scheduler_started do return true

	if !scheduled_prompt_db_init(data_dir) {
		fmt.println("scheduled_prompt_scheduler_start: db init failed")
		return false
	}

	scheduled_prompt_scheduler_started = true
	scheduled_prompt_scheduler_running = true
	thread.run(scheduled_prompt_scheduler_worker)
	return true
}

scheduled_prompt_scheduler_stop :: proc() {
	scheduled_prompt_scheduler_running = false
	scheduled_prompt_db_close()
}

scheduled_prompt_scheduler_worker :: proc() {
	for scheduled_prompt_scheduler_running {
		scheduled_prompt_scheduler_tick()
		time.sleep(1 * time.Second)
	}
}

scheduled_prompt_scheduler_tick :: proc() {
	recs, ok := scheduled_prompt_db_load_all()
	if !ok do return
	defer delete(recs)

	now := router_now_unix_ms()

	for &rec in recs {
		if rec.status != "active" do continue
		if now < rec.next_run_unix_ms do continue

		// Trigger prompt
		message_id, msg_ok := chat_store_append_message("operator@local", rec.agent_instance_id, "user_to_agent", rec.prompt, false)
		if msg_ok {
			sent := chat_event_fanout("operator@local", rec.agent_instance_id, message_id, "user_to_agent")
			if agent_chat_notify_user_message(rec.agent_instance_id, "operator@local", message_id) {
				if chat_store_append_event(Chat_Event{kind = .Delivered_Marked, user_id = "operator@local", agent_instance_id = rec.agent_instance_id, message_id = message_id, direction = "user_to_agent", delivered_unix_ms = router_now_unix_ms()}) {
					chat_event_fanout("operator@local", rec.agent_instance_id, message_id, "delivered")
				}
			}
			fmt.printfln("SCHEDULED PROMPT: Triggered prompt for agent '%s': %s (message_id=%s)", rec.agent_instance_id, rec.prompt, message_id)
		} else {
			fmt.printfln("SCHEDULED PROMPT ERROR: Failed to trigger prompt for agent '%s'", rec.agent_instance_id)
		}

		// Update timestamps
		rec.last_run_unix_ms = now
		interval_sec := 60
		if val, parse_ok := strconv.parse_int(rec.schedule_expr); parse_ok {
			interval_sec = val
		}
		if interval_sec <= 0 do interval_sec = 60
		rec.next_run_unix_ms = now + i64(interval_sec) * 1000
		rec.updated_at_unix_ms = now

		if !scheduled_prompt_db_save(rec) {
			fmt.printfln("SCHEDULED PROMPT ERROR: Failed to save updated scheduled prompt '%s'", rec.scheduled_prompt_id)
		}

		// Free strings of record
		delete(rec.scheduled_prompt_id)
		delete(rec.agent_instance_id)
		delete(rec.prompt)
		delete(rec.schedule_type)
		delete(rec.schedule_expr)
		delete(rec.status)
	}
}
