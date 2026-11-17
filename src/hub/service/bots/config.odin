package bots

import "core:encoding/json"
import "core:strings"

Bot_Timer_Config :: struct {
	bot_attempt_accept_ms:    i64,
	bot_attempt_silence_ms:   i64,
	bot_attempt_total_ms:     i64,
	bot_disconnect_grace_ms:  i64,
	bot_relocation_wait_ms:   i64,
	bot_busy_retry_ms:        i64,
	bot_waiting_recheck_ms:   i64,
	bot_max_rounds:           int,
	bot_idle_stop_ms:         i64,
	bot_supervisor_tick_ms:   i64,
	bot_pairing_ttl_ms:       i64,
	bot_channel_retention_ms: i64,
	bot_max_local_candidates: int,
	launch_ready_ms:          i64,
	read_ms:                  i64,
	read_extend_ms:           i64,
	read_max_extends:         int,
	idle_no_reply_ms:         i64,
	reply_cap_ms:             i64,
	progress_interval_ms:     i64,
}

default_bot_timer_config :: proc() -> Bot_Timer_Config {
	return {
		bot_attempt_accept_ms = 15000,
		bot_attempt_silence_ms = 90000,
		bot_attempt_total_ms = 3600000,
		bot_disconnect_grace_ms = 30000,
		bot_relocation_wait_ms = 240000,
		bot_busy_retry_ms = 120000,
		bot_waiting_recheck_ms = 30000,
		bot_max_rounds = 3,
		bot_idle_stop_ms = 1800000,
		bot_supervisor_tick_ms = 1000,
		bot_pairing_ttl_ms = 600000,
		bot_channel_retention_ms = 2592000000,
		bot_max_local_candidates = 3,
		launch_ready_ms = 120000,
		read_ms = 60000,
		read_extend_ms = 60000,
		read_max_extends = 4,
		idle_no_reply_ms = 120000,
		reply_cap_ms = 1800000,
		progress_interval_ms = 30000,
	}
}

// apply_bot_timers_json preserves defaults for absent keys and refuses unknown
// keys and noninteger values without including the supplied JSON in errors.
apply_bot_timers_json :: proc(config: ^Bot_Timer_Config, raw: string) -> bool {
	if config == nil do return false
	text := strings.trim_space(raw)
	if len(text) < 2 || text[0] != '{' || text[len(text) - 1] != '}' do return false
	values: map[string]i64
	if err := json.unmarshal(transmute([]u8)text, &values); err != nil do return false
	defer {
		for key in values do delete(key)
		delete(values)
	}
	next := config^
	for key, value in values {
		switch key {
		case "bot_attempt_accept_ms":
			next.bot_attempt_accept_ms = value
		case "bot_attempt_silence_ms":
			next.bot_attempt_silence_ms = value
		case "bot_attempt_total_ms":
			next.bot_attempt_total_ms = value
		case "bot_disconnect_grace_ms":
			next.bot_disconnect_grace_ms = value
		case "bot_relocation_wait_ms":
			next.bot_relocation_wait_ms = value
		case "bot_busy_retry_ms":
			next.bot_busy_retry_ms = value
		case "bot_waiting_recheck_ms":
			next.bot_waiting_recheck_ms = value
		case "bot_max_rounds":
			next.bot_max_rounds = int(value)
		case "bot_idle_stop_ms":
			next.bot_idle_stop_ms = value
		case "bot_supervisor_tick_ms":
			next.bot_supervisor_tick_ms = value
		case "bot_pairing_ttl_ms":
			next.bot_pairing_ttl_ms = value
		case "bot_channel_retention_ms":
			next.bot_channel_retention_ms = value
		case "bot_max_local_candidates":
			next.bot_max_local_candidates = int(value)
		case "launch_ready_ms":
			next.launch_ready_ms = value
		case "read_ms":
			next.read_ms = value
		case "read_extend_ms":
			next.read_extend_ms = value
		case "read_max_extends":
			next.read_max_extends = int(value)
		case "idle_no_reply_ms":
			next.idle_no_reply_ms = value
		case "reply_cap_ms":
			next.reply_cap_ms = value
		case "progress_interval_ms":
			next.progress_interval_ms = value
		case:
			return false
		}
	}
	config^ = next
	return true
}
