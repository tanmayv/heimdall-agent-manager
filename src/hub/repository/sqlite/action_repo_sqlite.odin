package sqlite

import "core:fmt"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Action_Repo_SQLite :: struct { conn: ^Conn }

new_action_repository :: proc(impl: ^Action_Repo_SQLite, conn: ^Conn) -> iface.Action_Repository {
	impl.conn = conn
	return {ctx = impl,
 runs_route_batch=actions_runs_route_batch, target_open_delivery=actions_target_open_delivery,
 rules_for_owner=actions_rules_for_owner, triggers_for_owner=actions_triggers_for_owner,
 runs_history=actions_runs_history, runs_sweep=actions_runs_sweep,
		save = actions_save,
		get = actions_get,
		list = actions_list,
		delete_action = actions_delete_action,
		set_last_spawned = actions_set_last_spawned,
		rules_list = actions_rules_list,
		rules_replace = actions_rules_replace,
		trigger_save = actions_trigger_save,
		trigger_get = actions_trigger_get,
		trigger_delete = actions_trigger_delete,
		triggers_list = actions_triggers_list,
		triggers_match = actions_triggers_match,
		triggers_effective = actions_triggers_effective,
		run_insert = actions_run_insert,
        run_settle_pending = actions_run_settle_pending,
        run_settle_waiting = actions_run_settle_waiting,
		run_get = actions_run_get,
		run_open = actions_run_open,
		runs_due = actions_runs_due,
		runs_deferred = actions_runs_deferred,
		run_transition = actions_run_transition,
		run_last_started_at = actions_run_last_started_at,
		run_joined_count = actions_run_joined_count,
		runs_list = actions_runs_list,
		runs_prune = actions_runs_prune,
	}
}

actions_prepare :: proc(ctx: rawptr, query: string, params: []string) -> (sqlite3_stmt, domain.Domain_Error) {
	impl := (^Action_Repo_SQLite)(ctx)
	if impl == nil || impl.conn == nil || impl.conn.db == nil do return nil, domain.domain_error(.Internal_Error, "actions repository is not open")
	stmt: sqlite3_stmt
	if sqlite3_prepare_v2(impl.conn.db, strings.clone_to_cstring(query, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "could not prepare actions query")
	for value, i in params do bind_text(stmt, i + 1, value)
	return stmt, {}
}
actions_write :: proc(ctx: rawptr, query: string, params: []string) -> (bool, domain.Domain_Error) {
	stmt, err := actions_prepare(ctx, query, params)
	if err.code != .None do return false, err
	defer sqlite3_finalize(stmt)
	rc := sqlite3_step(stmt)
	if rc != SQLITE_DONE do return false, domain.domain_error(.Conflict if rc == SQLITE_CONSTRAINT else .Internal_Error, "could not write actions record")
	return sqlite3_changes((^Action_Repo_SQLite)(ctx).conn.db) != 0, {}
}

ACTIONS_ACTION_COLUMNS :: "action_id,owner_user_id,name,prompt_text,target_kind,target_agent_id,target_project_id,target_instance_id,target_bot_id,instance_strategy,placement_selector,last_spawned_instance_id,enabled,min_interval_s,created_at,updated_at"
actions_action_read :: proc(stmt: sqlite3_stmt) -> domain.Action {
	return {
		id = domain.Action_ID(column_text(stmt,0)),
		owner_user_id = domain.User_ID(column_text(stmt,1)),
		name = string(column_text(stmt,2)),
		prompt_text = string(column_text(stmt,3)),
		target_kind = string(column_text(stmt,4)),
		target_agent_id = domain.Agent_ID(column_text(stmt,5)),
		target_project_id = domain.Project_ID(column_text(stmt,6)),
		target_instance_id = domain.Agent_Instance_ID(column_text(stmt,7)),
		target_bot_id = string(column_text(stmt,8)),
		instance_strategy = string(column_text(stmt,9)),
		placement_selector = string(column_text(stmt,10)),
		last_spawned_instance_id = domain.Agent_Instance_ID(column_text(stmt,11)),
		enabled = sqlite3_column_int64(stmt,12) != 0,
		min_interval_s = int(sqlite3_column_int64(stmt,13)),
		created_at = string(column_text(stmt,14)),
		updated_at = string(column_text(stmt,15)),
	}
}

actions_action_query :: proc(ctx: rawptr, query: string, params: []string) -> ([]domain.Action, domain.Domain_Error) {
	stmt, err := actions_prepare(ctx, query, params)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows: [dynamic]domain.Action
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &r in rows do domain.action_destroy(&r)
			delete(rows)
			return nil, domain.domain_error(.Internal_Error, "could not read actions records")
		}
		append(&rows, actions_action_read(stmt))
	}
	result := make([]domain.Action, len(rows))
	copy(result, rows[:])
	delete(rows)
	return result, {}
}

ACTIONS_TRIGGER_COLUMNS :: "trigger_id,action_id,owner_user_id,kind,config,event_type,subject_filter,match_key,data_filter,enabled,rev,created_at,updated_at,delay_s"
actions_trigger_read :: proc(stmt: sqlite3_stmt) -> domain.Action_Trigger {
	return {
		trigger_id = string(column_text(stmt,0)),
		action_id = domain.Action_ID(column_text(stmt,1)),
		owner_user_id = domain.User_ID(column_text(stmt,2)),
		kind = string(column_text(stmt,3)),
		config_json = string(column_text(stmt,4)),
		event_type = string(column_text(stmt,5)),
		subject_filter = string(column_text(stmt,6)),
		match_key = string(column_text(stmt,7)),
		data_filter_json = string(column_text(stmt,8)),
		enabled = sqlite3_column_int64(stmt,9) != 0,
		rev = int(sqlite3_column_int64(stmt,10)),
		created_at = string(column_text(stmt,11)),
		updated_at = string(column_text(stmt,12)),
        delay_s = int(sqlite3_column_int64(stmt,13)),
	}
}

actions_trigger_query :: proc(ctx: rawptr, query: string, params: []string) -> ([]domain.Action_Trigger, domain.Domain_Error) {
	stmt, err := actions_prepare(ctx, query, params)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows: [dynamic]domain.Action_Trigger
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			domain.action_triggers_destroy(rows[:])
			return nil, domain.domain_error(.Internal_Error, "could not read actions records")
		}
		append(&rows, actions_trigger_read(stmt))
	}
	result := make([]domain.Action_Trigger, len(rows))
	copy(result, rows[:])
	delete(rows)
	return result, {}
}

ACTIONS_RUN_COLUMNS :: "run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending"
actions_run_read :: proc(stmt: sqlite3_stmt) -> domain.Action_Run {
	return {
		run_id = string(column_text(stmt,0)),
		action_id = domain.Action_ID(column_text(stmt,1)),
		trigger_id = string(column_text(stmt,2)),
		owner_user_id = domain.User_ID(column_text(stmt,3)),
		occurrence_key = string(column_text(stmt,4)),
		event_type = string(column_text(stmt,5)),
		event_id = string(column_text(stmt,6)),
		stream_sequence = i64(sqlite3_column_int64(stmt,7)),
		event_params_json = string(column_text(stmt,8)),
		state = string(column_text(stmt,9)),
		not_before = string(column_text(stmt,10)),
		joined_run_id = string(column_text(stmt,11)),
		reason = string(column_text(stmt,12)),
		rule_position = int(sqlite3_column_int64(stmt,13)),
		target_instance_id = string(column_text(stmt,14)),
		message_id = string(column_text(stmt,15)),
		delivery_id = string(column_text(stmt,16)),
		created_at = string(column_text(stmt,17)),
		started_at = string(column_text(stmt,18)),
		finished_at = string(column_text(stmt,19)),
        delay_s = int(sqlite3_column_int64(stmt,20)),
        settle_key = column_text(stmt,21),
        settle_pending = sqlite3_column_int64(stmt,22) != 0,
	}
}

actions_run_query :: proc(ctx: rawptr, query: string, params: []string) -> ([]domain.Action_Run, domain.Domain_Error) {
	stmt, err := actions_prepare(ctx, query, params)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows: [dynamic]domain.Action_Run
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			domain.action_runs_destroy(rows[:])
			return nil, domain.domain_error(.Internal_Error, "could not read actions records")
		}
		append(&rows, actions_run_read(stmt))
	}
	result := make([]domain.Action_Run, len(rows))
	copy(result, rows[:])
	delete(rows)
	return result, {}
}

ACTIONS_RULE_COLUMNS :: "position,bridge_id,provider,model"
actions_rule_read :: proc(stmt: sqlite3_stmt) -> domain.Action_Target_Rule {
	return {
		position = int(sqlite3_column_int64(stmt,0)),
		bridge_id = string(column_text(stmt,1)),
		provider = string(column_text(stmt,2)),
		model = string(column_text(stmt,3)),
	}
}

actions_rule_query :: proc(ctx: rawptr, query: string, params: []string) -> ([]domain.Action_Target_Rule, domain.Domain_Error) {
	stmt, err := actions_prepare(ctx, query, params)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	rows: [dynamic]domain.Action_Target_Rule
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			domain.action_rules_destroy(rows[:])
			return nil, domain.domain_error(.Internal_Error, "could not read actions records")
		}
		append(&rows, actions_rule_read(stmt))
	}
	result := make([]domain.Action_Target_Rule, len(rows))
	copy(result, rows[:])
	delete(rows)
	return result, {}
}

ACTIONS_SQL_SAVE :: "INSERT INTO actions(action_id,owner_user_id,name,prompt_text,target_kind,target_agent_id,target_project_id,target_instance_id,target_bot_id,instance_strategy,placement_selector,last_spawned_instance_id,enabled,min_interval_s,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16) ON CONFLICT(action_id) DO UPDATE SET name=excluded.name,prompt_text=excluded.prompt_text,target_kind=excluded.target_kind,target_agent_id=excluded.target_agent_id,target_project_id=excluded.target_project_id,target_instance_id=excluded.target_instance_id,target_bot_id=excluded.target_bot_id,instance_strategy=excluded.instance_strategy,placement_selector=excluded.placement_selector,last_spawned_instance_id=excluded.last_spawned_instance_id,enabled=excluded.enabled,min_interval_s=excluded.min_interval_s,updated_at=excluded.updated_at;"

actions_save :: proc(ctx: rawptr, v: domain.Action) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := actions_write(ctx,ACTIONS_SQL_SAVE,{string(v.id),string(v.owner_user_id),string(v.name),string(v.prompt_text),string(v.target_kind),string(v.target_agent_id),string(v.target_project_id),string(v.target_instance_id),string(v.target_bot_id),string(v.instance_strategy),string(v.placement_selector),string(v.last_spawned_instance_id),("1" if v.enabled else "0"),fmt.tprintf("%d",v.min_interval_s),string(v.created_at),string(v.updated_at)})
	return err
}

ACTIONS_SQL_TRIGGER_SAVE :: "INSERT INTO action_triggers(trigger_id,action_id,owner_user_id,kind,config,event_type,subject_filter,match_key,data_filter,enabled,rev,created_at,updated_at,delay_s) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14) ON CONFLICT(trigger_id) DO UPDATE SET kind=excluded.kind,config=excluded.config,event_type=excluded.event_type,subject_filter=excluded.subject_filter,match_key=excluded.match_key,data_filter=excluded.data_filter,enabled=excluded.enabled,rev=excluded.rev,updated_at=excluded.updated_at,delay_s=excluded.delay_s;"

actions_trigger_save :: proc(ctx: rawptr, v: domain.Action_Trigger) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := actions_write(ctx,ACTIONS_SQL_TRIGGER_SAVE,{string(v.trigger_id),string(v.action_id),string(v.owner_user_id),string(v.kind),string(v.config_json),string(v.event_type),string(v.subject_filter),string(v.match_key),string(v.data_filter_json),("1" if v.enabled else "0"),fmt.tprintf("%d",v.rev),string(v.created_at),string(v.updated_at),fmt.tprintf("%d",v.delay_s)})
	return err
}

ACTIONS_SQL_RUN_INSERT :: "INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23) ON CONFLICT(occurrence_key) DO NOTHING;"

actions_run_insert :: proc(ctx: rawptr, v: domain.Action_Run) -> (bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_write(ctx,ACTIONS_SQL_RUN_INSERT,{string(v.run_id),string(v.action_id),string(v.trigger_id),string(v.owner_user_id),string(v.occurrence_key),string(v.event_type),string(v.event_id),fmt.tprintf("%d",v.stream_sequence),string(v.event_params_json),string(v.state),string(v.not_before),string(v.joined_run_id),string(v.reason),fmt.tprintf("%d",v.rule_position),string(v.target_instance_id),string(v.message_id),string(v.delivery_id),string(v.created_at),string(v.started_at),string(v.finished_at),fmt.tprintf("%d",v.delay_s),v.settle_key,("1" if v.settle_pending else "0")})
}

ACTIONS_SQL_GET :: "SELECT action_id,owner_user_id,name,prompt_text,target_kind,target_agent_id,target_project_id,target_instance_id,target_bot_id,instance_strategy,placement_selector,last_spawned_instance_id,enabled,min_interval_s,created_at,updated_at FROM actions WHERE action_id=?1;"

actions_get :: proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action, bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	rows, err := actions_action_query(ctx,ACTIONS_SQL_GET,{string(id)})
	defer delete(rows)
	if err.code != .None || len(rows)==0 do return {},false,err
	return rows[0],true,{}
}

ACTIONS_SQL_TRIGGER_GET :: "SELECT trigger_id,action_id,owner_user_id,kind,config,event_type,subject_filter,match_key,data_filter,enabled,rev,created_at,updated_at,delay_s FROM action_triggers WHERE trigger_id=?1;"

actions_trigger_get :: proc(ctx: rawptr, id: string) -> (domain.Action_Trigger, bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	rows, err := actions_trigger_query(ctx,ACTIONS_SQL_TRIGGER_GET,{string(id)})
	defer delete(rows)
	if err.code != .None || len(rows)==0 do return {},false,err
	return rows[0],true,{}
}

ACTIONS_SQL_RUN_GET :: "SELECT run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending FROM action_runs WHERE run_id=?1;"

actions_run_get :: proc(ctx: rawptr, id: string) -> (domain.Action_Run, bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	rows, err := actions_run_query(ctx,ACTIONS_SQL_RUN_GET,{string(id)})
	defer delete(rows)
	if err.code != .None || len(rows)==0 do return {},false,err
	return rows[0],true,{}
}

ACTIONS_SQL_RUN_OPEN :: "SELECT run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending FROM action_runs WHERE action_id=?1 AND state IN ('queued','deferred','routed') AND settle_pending=0;"

actions_run_open :: proc(ctx: rawptr, id: domain.Action_ID) -> (domain.Action_Run, bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	rows, err := actions_run_query(ctx,ACTIONS_SQL_RUN_OPEN,{string(id)})
	defer delete(rows)
	if err.code != .None || len(rows)==0 do return {},false,err
	return rows[0],true,{}
}

ACTIONS_SQL_LIST :: "SELECT action_id,owner_user_id,name,prompt_text,target_kind,target_agent_id,target_project_id,target_instance_id,target_bot_id,instance_strategy,placement_selector,last_spawned_instance_id,enabled,min_interval_s,created_at,updated_at FROM actions WHERE owner_user_id=?1 ORDER BY created_at,action_id;"

actions_list :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Action, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_action_query(ctx,ACTIONS_SQL_LIST,{string(owner)})
}

ACTIONS_SQL_RULES_LIST :: "SELECT position,bridge_id,provider,model FROM action_target_rules WHERE action_id=?1 ORDER BY position;"

actions_rules_list :: proc(ctx: rawptr, id: domain.Action_ID) -> ([]domain.Action_Target_Rule, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_rule_query(ctx,ACTIONS_SQL_RULES_LIST,{string(id)})
}

ACTIONS_SQL_TRIGGERS_LIST :: "SELECT trigger_id,action_id,owner_user_id,kind,config,event_type,subject_filter,match_key,data_filter,enabled,rev,created_at,updated_at,delay_s FROM action_triggers WHERE action_id=?1 ORDER BY created_at,trigger_id;"

actions_triggers_list :: proc(ctx: rawptr, id: domain.Action_ID) -> ([]domain.Action_Trigger, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_trigger_query(ctx,ACTIONS_SQL_TRIGGERS_LIST,{string(id)})
}

ACTIONS_SQL_TRIGGERS_MATCH :: "SELECT t.trigger_id,t.action_id,t.owner_user_id,t.kind,t.config,t.event_type,t.subject_filter,t.match_key,t.data_filter,t.enabled,t.rev,t.created_at,t.updated_at,t.delay_s FROM action_triggers t JOIN actions a ON a.action_id=t.action_id WHERE t.owner_user_id=?1 AND t.event_type=?2 AND (t.match_key=?3 OR t.match_key='') AND t.enabled=1 AND a.enabled=1 ORDER BY t.created_at,t.trigger_id;"

actions_triggers_match :: proc(ctx: rawptr, owner,event_type,subject: string) -> ([]domain.Action_Trigger, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_trigger_query(ctx,ACTIONS_SQL_TRIGGERS_MATCH,{owner,event_type,subject})
}

ACTIONS_SQL_TRIGGERS_EFFECTIVE :: "SELECT t.trigger_id,t.action_id,t.owner_user_id,t.kind,t.config,t.event_type,t.subject_filter,t.match_key,t.data_filter,t.enabled,t.rev,t.created_at,t.updated_at,t.delay_s FROM action_triggers t JOIN actions a ON a.action_id=t.action_id WHERE t.kind=?1 AND t.enabled=1 AND a.enabled=1 ORDER BY t.created_at,t.trigger_id;"

actions_triggers_effective :: proc(ctx: rawptr, kind: string) -> ([]domain.Action_Trigger, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_trigger_query(ctx,ACTIONS_SQL_TRIGGERS_EFFECTIVE,{kind})
}

ACTIONS_SQL_RUNS_DUE :: "SELECT run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending FROM action_runs WHERE state IN ('queued','deferred') AND (state='queued' OR not_before<=?1) ORDER BY created_at,run_id LIMIT ?2;"

actions_runs_due :: proc(ctx: rawptr, now: string, limit: int) -> ([]domain.Action_Run, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_run_query(ctx,ACTIONS_SQL_RUNS_DUE,{now,fmt.tprintf("%d",limit)})
}

ACTIONS_SQL_RUNS_DEFERRED :: "SELECT run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending FROM action_runs WHERE state IN ('queued','deferred') AND state='deferred' ORDER BY created_at,run_id LIMIT ?1;"

actions_runs_deferred :: proc(ctx: rawptr, limit: int) -> ([]domain.Action_Run, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_run_query(ctx,ACTIONS_SQL_RUNS_DEFERRED,{fmt.tprintf("%d",limit)})
}

ACTIONS_SQL_RUNS_LIST :: "SELECT run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,event_id,stream_sequence,event_params,state,not_before,joined_run_id,reason,rule_position,target_instance_id,message_id,delivery_id,created_at,started_at,finished_at,delay_s,settle_key,settle_pending FROM action_runs WHERE action_id=?1 AND (?2='' OR created_at<?2 OR (?4!='' AND created_at=?2 AND run_id<?4)) ORDER BY created_at DESC,run_id DESC LIMIT ?3;"

actions_runs_list :: proc(ctx: rawptr, id: domain.Action_ID, limit: int, before_created_at: string, before_id: string) -> ([]domain.Action_Run, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_run_query(ctx,ACTIONS_SQL_RUNS_LIST,{string(id),before_created_at,fmt.tprintf("%d",limit),before_id})
}

actions_set_last_spawned :: proc(ctx: rawptr, id: domain.Action_ID, instance_id, updated_at: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := actions_write(ctx, "UPDATE actions SET last_spawned_instance_id=?2,updated_at=?3 WHERE action_id=?1;", {string(id),instance_id,updated_at})
	return err
}
actions_trigger_delete :: proc(ctx: rawptr, trigger_id: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := actions_write(ctx, "DELETE FROM action_triggers WHERE trigger_id=?1;", {trigger_id})
	return err
}
// Savepoints keep multi-statement writes atomic for direct callers and UoWs.
actions_delete_action :: proc(ctx: rawptr, id: domain.Action_ID) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := (^Action_Repo_SQLite)(ctx).conn
	if !exec(conn, "SAVEPOINT action_delete;") do return domain.domain_error(.Internal_Error, "could not begin action delete")
	done := false
	defer if !done {exec(conn, "ROLLBACK TO action_delete;"); exec(conn, "RELEASE action_delete;")}
	queries := [?]string{"DELETE FROM action_runs WHERE action_id=?1;", "DELETE FROM action_triggers WHERE action_id=?1;", "DELETE FROM action_target_rules WHERE action_id=?1;", "DELETE FROM actions WHERE action_id=?1;"}
	for query in queries {
		_, err := actions_write(ctx, query, {string(id)})
		if err.code != .None do return err
	}
	if !exec(conn, "RELEASE action_delete;") do return domain.domain_error(.Internal_Error, "could not finish action delete")
	done = true
	return {}
}
actions_rules_replace :: proc(ctx: rawptr, id: domain.Action_ID, rows: []domain.Action_Target_Rule) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := (^Action_Repo_SQLite)(ctx).conn
	if !exec(conn, "SAVEPOINT action_rules_replace;") do return domain.domain_error(.Internal_Error, "could not begin rules replace")
	done := false
	defer if !done {exec(conn, "ROLLBACK TO action_rules_replace;"); exec(conn, "RELEASE action_rules_replace;")}
	_, err := actions_write(ctx, "DELETE FROM action_target_rules WHERE action_id=?1;", {string(id)})
	if err.code != .None do return err
	for row in rows {
		_, err = actions_write(ctx, "INSERT INTO action_target_rules(action_id,position,bridge_id,provider,model) VALUES(?1,?2,?3,?4,?5);", {string(id),fmt.tprintf("%d",row.position),row.bridge_id,row.provider,row.model})
		if err.code != .None do return err
	}
	if !exec(conn, "RELEASE action_rules_replace;") do return domain.domain_error(.Internal_Error, "could not finish rules replace")
	done = true
	return {}
}

actions_run_transition :: proc(ctx: rawptr, v: domain.Action_Run, from_state: string) -> (bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	return actions_write(ctx,"UPDATE action_runs SET trigger_id=?3,event_type=?6,event_id=?7,stream_sequence=?8,event_params=?9,state=?10,not_before=?11,joined_run_id=?12,reason=?13,rule_position=?14,target_instance_id=?15,message_id=?16,delivery_id=?17,started_at=?19,finished_at=?20,delay_s=?21,settle_key=?22,settle_pending=?23 WHERE run_id=?1 AND state=?24;",{string(v.run_id),string(v.action_id),string(v.trigger_id),string(v.owner_user_id),string(v.occurrence_key),string(v.event_type),string(v.event_id),fmt.tprintf("%d",v.stream_sequence),string(v.event_params_json),string(v.state),string(v.not_before),string(v.joined_run_id),string(v.reason),fmt.tprintf("%d",v.rule_position),string(v.target_instance_id),string(v.message_id),string(v.delivery_id),string(v.created_at),string(v.started_at),string(v.finished_at),fmt.tprintf("%d",v.delay_s),v.settle_key,("1" if v.settle_pending else "0"),from_state})
}

ACTIONS_SQL_RUN_LAST_STARTED_AT :: "SELECT started_at FROM action_runs WHERE action_id=?1 AND started_at<>'' ORDER BY created_at DESC,run_id DESC LIMIT 1;"

actions_run_last_started_at :: proc(ctx: rawptr, id: domain.Action_ID) -> (string, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	stmt, err := actions_prepare(ctx, ACTIONS_SQL_RUN_LAST_STARTED_AT, {string(id)})
	if err.code != .None do return "", err
	defer sqlite3_finalize(stmt)
	rc := sqlite3_step(stmt)
	if rc == SQLITE_DONE do return "", {}
	if rc != SQLITE_ROW do return "", domain.domain_error(.Internal_Error, "could not read run start")
	return column_text(stmt, 0), {}
}
actions_run_joined_count :: proc(ctx: rawptr, run_id: string) -> (int, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	stmt, err := actions_prepare(ctx, "SELECT count(*) FROM action_runs WHERE joined_run_id=?1 AND state='joined';", {run_id})
	if err.code != .None do return 0, err
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return 0, domain.domain_error(.Internal_Error, "could not count joined runs")
	return int(sqlite3_column_int64(stmt, 0)), {}
}

ACTIONS_SQL_RUNS_PRUNE :: "DELETE FROM action_runs WHERE action_id=?1 AND state NOT IN ('queued','deferred','routed') AND (created_at<?2 OR run_id NOT IN (SELECT run_id FROM action_runs WHERE action_id=?1 ORDER BY created_at DESC,run_id DESC LIMIT ?3));"

actions_runs_prune :: proc(ctx: rawptr, id: domain.Action_ID, keep: int, cutoff: string) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	_, err := actions_write(ctx, ACTIONS_SQL_RUNS_PRUNE, {string(id),cutoff,fmt.tprintf("%d",keep)})
	return err
}

// Owner predicates are applied in SQL; child rows never cross owner boundaries.
ACTIONS_SQL_RULES_OWNER :: "SELECT r.position,r.bridge_id,r.provider,r.model,r.action_id FROM action_target_rules r JOIN actions a ON a.action_id=r.action_id WHERE a.owner_user_id=?1 ORDER BY r.action_id,r.position;"
actions_rules_for_owner :: proc(ctx:rawptr,owner:string)->([]iface.Action_Rule_Row,domain.Domain_Error) {
 guard:=tx_repository_enter(); defer tx_repository_leave(guard)
 stmt,err:=actions_prepare(ctx,ACTIONS_SQL_RULES_OWNER,{owner})
 if err.code!=.None do return nil,err
 defer sqlite3_finalize(stmt)
 rows:=make([dynamic]iface.Action_Rule_Row)
 for {
  rc:=sqlite3_step(stmt)
  if rc==SQLITE_DONE do return rows[:],{}
  if rc!=SQLITE_ROW {
   for row in rows {delete(row.action_id);delete(row.rule.bridge_id);delete(row.rule.provider);delete(row.rule.model)}
   delete(rows)
   return nil,domain.domain_error(.Internal_Error,"could not load action rules")
  }
  append(&rows,iface.Action_Rule_Row{column_text(stmt,4),actions_rule_read(stmt)})
 }
}
ACTIONS_SQL_TRIGGERS_OWNER :: "SELECT t.trigger_id,t.action_id,t.owner_user_id,t.kind,t.config,t.event_type,t.subject_filter,t.match_key,t.data_filter,t.enabled,t.rev,t.created_at,t.updated_at,t.delay_s FROM action_triggers t JOIN actions a ON a.action_id=t.action_id WHERE a.owner_user_id=?1 ORDER BY t.action_id,t.created_at,t.trigger_id;"
actions_triggers_for_owner :: proc(ctx:rawptr,owner:string)->([]domain.Action_Trigger,domain.Domain_Error) {
 guard:=tx_repository_enter(); defer tx_repository_leave(guard)
 return actions_trigger_query(ctx,ACTIONS_SQL_TRIGGERS_OWNER,{owner})
}
// Materialize the page before grouping joined rows, then join delivery expiry once.
ACTIONS_SQL_HISTORY :: "WITH page AS (SELECT " + ACTIONS_RUN_COLUMNS + " FROM action_runs WHERE action_id=?1 AND (?2='' OR created_at<?2 OR (?4!='' AND created_at=?2 AND run_id<?4)) ORDER BY created_at DESC,run_id DESC LIMIT ?3), counts AS (SELECT j.joined_run_id,count(*) AS n FROM page p CROSS JOIN action_runs j ON p.run_id=j.joined_run_id WHERE j.state='joined' GROUP BY j.joined_run_id) SELECT p.*,coalesce(c.n,0),CASE WHEN p.state='routed' THEN coalesce(d.expires_at,'') ELSE '' END,coalesce(d.state,''),coalesce(d.outcome,'') FROM page p LEFT JOIN counts c ON c.joined_run_id=p.run_id LEFT JOIN pipeline_deliveries d ON d.delivery_id=p.delivery_id ORDER BY p.created_at DESC,p.run_id DESC;"
actions_runs_history :: proc(ctx:rawptr,id:domain.Action_ID,limit:int,before,before_id:string)->([]iface.Action_Run_History,domain.Domain_Error) {
 guard:=tx_repository_enter(); defer tx_repository_leave(guard)
 stmt,err:=actions_prepare(ctx,ACTIONS_SQL_HISTORY,{string(id),before,fmt.tprintf("%d",limit),before_id})
 if err.code!=.None do return nil,err
 defer sqlite3_finalize(stmt)
 rows:=make([dynamic]iface.Action_Run_History)
 for {
  rc:=sqlite3_step(stmt)
  if rc==SQLITE_DONE do return rows[:],{}
  if rc!=SQLITE_ROW {
   for &row in rows {domain.action_run_destroy(&row.run);delete(row.delivery_expires_at);delete(row.delivery_state);delete(row.delivery_outcome)}
   delete(rows)
   return nil,domain.domain_error(.Internal_Error,"could not load action history")
  }
  append(&rows,iface.Action_Run_History{actions_run_read(stmt),int(sqlite3_column_int64(stmt,23)),column_text(stmt,24),column_text(stmt,25),column_text(stmt,26)})
 }
}
ACTIONS_SQL_SWEEP :: "DELETE FROM action_runs WHERE run_id IN (SELECT run_id FROM action_runs WHERE state NOT IN ('queued','deferred','routed') AND created_at<?1 ORDER BY created_at,run_id LIMIT ?2);"
actions_runs_sweep :: proc(ctx:rawptr,cutoff:string,limit:int)->domain.Domain_Error {
 guard:=tx_repository_enter(); defer tx_repository_leave(guard)
 _,err:=actions_write(ctx,ACTIONS_SQL_SWEEP,{cutoff,fmt.tprintf("%d",clamp(limit,1,128))})
 return err
}

actions_run_settle_pending :: proc(ctx: rawptr, trigger_id, settle_key: string) -> (domain.Action_Run, bool, domain.Domain_Error) {
 guard := tx_repository_enter(); defer tx_repository_leave(guard)
 rows, err := actions_run_query(ctx, "SELECT " + ACTIONS_RUN_COLUMNS + " FROM action_runs WHERE trigger_id=?1 AND settle_key=?2 AND state='deferred' AND settle_pending=1;", {trigger_id,settle_key})
 defer delete(rows)
 if err.code != .None || len(rows)==0 do return {},false,err
 return rows[0],true,{}
}


actions_run_settle_waiting :: proc(ctx: rawptr, id: domain.Action_ID, now: string) -> (bool, domain.Domain_Error) {
 guard := tx_repository_enter()
 defer tx_repository_leave(guard)
 stmt, err := actions_prepare(ctx, "SELECT EXISTS(SELECT 1 FROM action_runs WHERE action_id=?1 AND state='deferred' AND settle_pending=1 AND not_before<=?2);", {string(id),now})
 if err.code != .None do return false, err
 defer sqlite3_finalize(stmt)
 if sqlite3_step(stmt) != SQLITE_ROW do return false, domain.domain_error(.Internal_Error,"could not read waiting settle runs")
 return sqlite3_column_int64(stmt,0)!=0, {}
}

// Membership and expected state travel together so one statement cannot route a
// changed or missing member. The surrounding UoW rolls back on a short update.
actions_runs_route_batch :: proc(ctx:rawptr,members:[]iface.Action_Batch_Member,delivery_id,message_id,instance_id,started_at:string,rule_position:int)->domain.Domain_Error {
 guard:=tx_repository_enter()
 defer tx_repository_leave(guard)
 params:=make([dynamic]string,context.temp_allocator)
 append(&params,delivery_id,message_id,instance_id,started_at,fmt.tprintf("%d",rule_position))
 query:=strings.builder_make(context.temp_allocator)
 strings.write_string(&query,"UPDATE action_runs SET state='routed',delivery_id=?1,message_id=?2,target_instance_id=?3,started_at=?4,rule_position=?5 WHERE ")
 for member,i in members {
  if i>0 do strings.write_string(&query," OR ")
  strings.write_string(&query,fmt.tprintf("(run_id=?%d AND state=?%d)",6+i*2,7+i*2))
  append(&params,member.run_id,member.from_state)
 }
 if len(members)==0 do return {}
 _,err:=actions_write(ctx,strings.to_string(query),params[:])
 if err.code!=.None do return err
 if sqlite3_changes((^Action_Repo_SQLite)(ctx).conn.db)!=i32(len(members)) do return domain.domain_error(.Conflict,"action batch changed")
 return {}
}
// Keep both predicates: IN enables the partial index; equality excludes completed runs.
ACTIONS_SQL_TARGET_OPEN_DELIVERY :: "SELECT d.delivery_id,d.expires_at FROM action_runs r JOIN pipeline_deliveries d ON d.delivery_id=r.delivery_id WHERE r.owner_user_id=?1 AND r.target_instance_id=?2 AND r.state IN ('routed','delivered') AND r.state='routed' AND d.state IN ('routed','forwarded') ORDER BY d.created_at,d.delivery_id LIMIT 1;"
actions_target_open_delivery :: proc(ctx:rawptr,owner,instance_id:string)->(string,string,bool,domain.Domain_Error) {
 guard:=tx_repository_enter()
 defer tx_repository_leave(guard)
 stmt,err:=actions_prepare(ctx,ACTIONS_SQL_TARGET_OPEN_DELIVERY,{owner,instance_id})
 if err.code!=.None do return "","",false,err
 defer sqlite3_finalize(stmt)
 rc:=sqlite3_step(stmt)
 if rc==SQLITE_DONE do return "","",false,{}
 if rc!=SQLITE_ROW do return "","",false,domain.domain_error(.Internal_Error,"cannot read target delivery")
 return column_text(stmt,0),column_text(stmt,1),true,{}
}
