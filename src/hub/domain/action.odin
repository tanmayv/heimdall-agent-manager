package domain

ACTION_TARGET_AGENT    :: "agent"
ACTION_TARGET_INSTANCE :: "instance"
ACTION_TARGET_BOT      :: "bot"
ACTION_MAX_TRIGGERS    :: 16
ACTION_MAX_RULES       :: 16
ACTION_MIN_INTERVAL_DEFAULT_S :: 30
ACTION_MIN_INTERVAL_MIN_S     :: 5
ACTION_MIN_INTERVAL_MAX_S     :: 86400
ACTION_INSTANCE_STRATEGY_REUSE :: "reuse"
ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN :: "fresh_per_run"
action_instance_strategy_valid :: proc(s: string) -> bool {
	return s == "" || s == ACTION_INSTANCE_STRATEGY_REUSE || s == ACTION_INSTANCE_STRATEGY_FRESH_PER_RUN
}

Action :: struct {
	id:                       Action_ID,
	owner_user_id:            User_ID,
	name, prompt_text:        string,
	target_kind:              string,
	target_agent_id:          Agent_ID,
	target_project_id:        Project_ID,
	target_instance_id:       Agent_Instance_ID,
	target_bot_id:            string,
	instance_strategy:        string,
	placement_selector:       string,
	last_spawned_instance_id: Agent_Instance_ID,
	enabled:                  bool,
	min_interval_s:           int,
	created_at, updated_at:   string,
}
Action_Target_Rule :: struct {
	position: int,
	bridge_id, provider, model: string,
}
Action_Trigger :: struct {
	trigger_id:             string,
	action_id:              Action_ID,
	owner_user_id:          User_ID,
	kind:                   string,
	config_json:            string, // column config
	event_type:             string,
	subject_filter:         string,
	match_key:              string,
	data_filter_json:       string, // column data_filter
	enabled:                bool,
	rev:                    int,
	created_at, updated_at: string,
}
Action_Run :: struct {
	run_id:                             string,
	action_id:                          Action_ID,
	trigger_id:                         string,
	owner_user_id:                      User_ID,
	occurrence_key:                     string,
	event_type, event_id:               string,
	stream_sequence:                    i64,
	event_params_json:                  string,
	state:                              string, // ACTION_RUN_* below
	not_before, joined_run_id, reason:  string,
	rule_position:                      int,
	target_instance_id, message_id:     string,
	delivery_id:                        string,
	created_at, started_at, finished_at: string,
}
ACTION_RUN_QUEUED :: "queued"
ACTION_RUN_DEFERRED :: "deferred"; ACTION_RUN_DELIVERED :: "delivered"
ACTION_RUN_ROUTED :: "routed"
// True for queued, deferred and routed.
action_run_open :: proc(state: string) -> bool {
	return state == ACTION_RUN_QUEUED || state == ACTION_RUN_DEFERRED || state == ACTION_RUN_ROUTED
}
ACTION_RUN_JOINED :: "joined"
ACTION_RUN_SKIPPED  :: "skipped";  ACTION_RUN_FAILED    :: "failed"


action_destroy :: proc(v: ^Action) {
	delete(string(v.id))
	delete(string(v.owner_user_id))
	delete(string(v.name))
	delete(string(v.prompt_text))
	delete(string(v.target_kind))
	delete(string(v.target_agent_id))
	delete(string(v.target_project_id))
	delete(string(v.target_instance_id))
	delete(string(v.target_bot_id))
	delete(string(v.instance_strategy))
	delete(string(v.placement_selector))
	delete(string(v.last_spawned_instance_id))
	delete(string(v.created_at))
	delete(string(v.updated_at))
	v^ = {}
}

action_trigger_destroy :: proc(v: ^Action_Trigger) {
	delete(string(v.trigger_id))
	delete(string(v.action_id))
	delete(string(v.owner_user_id))
	delete(string(v.kind))
	delete(string(v.config_json))
	delete(string(v.event_type))
	delete(string(v.subject_filter))
	delete(string(v.match_key))
	delete(string(v.data_filter_json))
	delete(string(v.created_at))
	delete(string(v.updated_at))
	v^ = {}
}

action_run_destroy :: proc(v: ^Action_Run) {
	delete(string(v.run_id))
	delete(string(v.action_id))
	delete(string(v.trigger_id))
	delete(string(v.owner_user_id))
	delete(string(v.occurrence_key))
	delete(string(v.event_type))
	delete(string(v.event_id))
	delete(string(v.event_params_json))
	delete(string(v.state))
	delete(string(v.not_before))
	delete(string(v.joined_run_id))
	delete(string(v.reason))
	delete(string(v.target_instance_id))
	delete(string(v.message_id))
	delete(string(v.delivery_id))
	delete(string(v.created_at))
	delete(string(v.started_at))
	delete(string(v.finished_at))
	v^ = {}
}

action_triggers_destroy :: proc(rows: []Action_Trigger) {
	for &row in rows do action_trigger_destroy(&row)
	delete(rows)
}

action_runs_destroy :: proc(rows: []Action_Run) {
	for &row in rows do action_run_destroy(&row)
	delete(rows)
}

action_rules_destroy :: proc(rows: []Action_Target_Rule) {
	for row in rows {
		delete(row.bridge_id); delete(row.provider); delete(row.model)
	}
	delete(rows)
}
