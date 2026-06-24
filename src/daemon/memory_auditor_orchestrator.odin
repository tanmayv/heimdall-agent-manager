package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"
import cfg_lib "odin_test:lib/config"

PROMPT_AUDIT_CHAIN_DESC :: #load("../prompts/memory_audit_chain_description.md", string)
PROMPT_AUDIT_TASK_1    :: #load("../prompts/memory_audit_task_1.md", string)
PROMPT_AUDIT_TASK_2    :: #load("../prompts/memory_audit_task_2.md", string)
PROMPT_AUDIT_TASK_3    :: #load("../prompts/memory_audit_task_3.md", string)
PROMPT_AUDIT_TASK_4    :: #load("../prompts/memory_audit_task_4.md", string)
PROMPT_AUDIT_TASK_5    :: #load("../prompts/memory_audit_task_5.md", string)

safe_replace :: proc(s, old, new: string) -> string {
	res, _ := strings.replace_all(s, old, new)
	if raw_data(res) != raw_data(s) {
		delete(s)
	}
	return res
}

populate_prompt_template :: proc(template_str, timeframe, target_chains, instructions: string) -> string {
	current := strings.clone(template_str)
	current = safe_replace(current, "{{TIMEFRAME}}", timeframe)
	current = safe_replace(current, "{{TARGET_CHAINS}}", target_chains)
	inst := instructions
	if inst == "" do inst = "None"
	current = safe_replace(current, "{{AUDITOR_INSTRUCTIONS}}", inst)
	return current
}

handle_post_task_chain_audit :: proc(client: net.TCP_Socket, body: string, ctx: ^Route_Context) {
	author, ok := rest_authorize(client, ctx)
	if !ok do return

	// 1. Verify Memory Auditor is enabled
	enabled_str := memory_auditor_resolve_pref(author, "memory_auditor_enabled")
	defer delete(enabled_str)
	if enabled_str != "true" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"Memory Auditor is disabled in user preferences"}`)
		return
	}

	// 1b. Verify Auditor and Reviewer are registered known agent instances
	auditor_agent_id := memory_auditor_resolve_pref(author, "memory_auditor_agent_id")
	reviewer_agent_id := memory_auditor_resolve_pref(author, "memory_reviewer_agent_id")
	defer delete(auditor_agent_id)
	defer delete(reviewer_agent_id)

	auditor_idx := agent_record_index_by_instance(auditor_agent_id)
	reviewer_idx := agent_record_index_by_instance(reviewer_agent_id)

	if auditor_idx < 0 || reviewer_idx < 0 {
		fmt.printfln("WARNING: Memory Audit requested but Auditor '%s' (found=%t) or Reviewer '%s' (found=%t) are not registered known agents. Audit rejected.", 
			auditor_agent_id, auditor_idx >= 0, reviewer_agent_id, reviewer_idx >= 0)
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"Memory Auditor or Reviewer agent instances are not registered known agents in the system."}`)
		return
	}

	// 2. Parse request parameters
	manual_chains := extract_json_string_array(body, "target_chains")
	defer delete(manual_chains)

	time_range := extract_json_string(body, "time_range", "")
	auditor_instructions := extract_json_string(body, "auditor_instructions", "")
	defer delete(auditor_instructions)

	if len(manual_chains) == 0 && time_range == "" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"either 'target_chains' array or 'time_range' string must be provided"}`)
		return
	}

	if time_range != "" && time_range != "1h" && time_range != "24h" && time_range != "1d" && time_range != "7d" && time_range != "all" {
		write_response(client, 400, "Bad Request", `{"ok":false,"message":"invalid time_range; expected 1h, 24h, 1d, 7d, or all"}`)
		return
	}

	// 3. Prevent duplicate active audits
	active_run, is_active := audit_db_get_active_run()
	if is_active {
		defer audit_run_free(active_run)
		write_response(client, 409, "Conflict", fmt.tprintf("{\"ok\":false,\"message\":\"Another memory audit run is currently active (ID: %s). Please wait for it to complete or time out.\"}", active_run.audit_id))
		return
	}

	// 4. Determine target chains for the audit run
	target_chains := make([dynamic]string, context.allocator)
	defer delete(target_chains)

	now := now_unix_ms()

	if len(manual_chains) > 0 {
		for chain_id in manual_chains {
			if idx := task_chain_index_of(chain_id); idx >= 0 {
				append(&target_chains, strings.clone(chain_id))
			} else {
				write_response(client, 400, "Bad Request", fmt.tprintf("{{\"ok\":false,\"message\":\"specified task chain '%s' does not exist\"}}", chain_id))
				return
			}
		}
	} else {
		since_ms := i64(0)
		if time_range != "all" {
			since_ms = now - delta_unix_ms(time_range)
		}
		for i in 0..<task_chain_count {
			chain := task_chains[i]
			if chain.status != "completed" || chain.evaluation != "good" do continue
			if time_range == "all" || chain.completed_at_unix_ms >= since_ms {
				append(&target_chains, strings.clone(chain.chain_id))
			}
		}
	}

	// 5. Handle empty targets
	if len(target_chains) == 0 {
		write_response(client, 200, "OK", `{"ok":true,"message":"No task chains found for the selected audit target.","target_chains_count":0}`)
		return
	}

	// 6. Serialize target chains to JSON array
	chains_builder := strings.builder_make()
	strings.write_string(&chains_builder, `[`)
	for chain_id, idx in target_chains {
		if idx > 0 do strings.write_string(&chains_builder, `,`)
		strings.write_string(&chains_builder, `"`)
		json_write_string(&chains_builder, chain_id)
		strings.write_string(&chains_builder, `"`)
	}
	strings.write_string(&chains_builder, `]`)
	target_chains_json := strings.to_string(chains_builder)

	// 7. Create Audit Run in database
	audit_id := fmt.tprintf("audit_%d", now)
	run_time_range := time_range
	if run_time_range == "" do run_time_range = "manual"
	run := Audit_Run{
		audit_id           = strings.clone(audit_id),
		time_range         = strings.clone(run_time_range),
		status             = strings.clone("started"),
		target_chains_json = target_chains_json,
		started_at_unix_ms = now,
		failure_reason     = strings.clone(""),
	}
	if !audit_db_create_run(run) {
		audit_run_free(run)
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to create audit run in database"}`)
		return
	}
	defer audit_run_free(run) // Local copy cleanup

	// 8. Resolve Memory Auditor Agent Configs
	auditor_model_tier := memory_auditor_resolve_pref(author, "memory_auditor_model_tier")
	auditor_provider_profile := memory_auditor_resolve_pref(author, "memory_auditor_provider_profile")
	defer delete(auditor_model_tier)
	defer delete(auditor_provider_profile)

	// 9. Create Audit Task Chain in 'heimdall-system' project
	system_project_id := "heimdall-system"
	audit_chain_id := fmt.tprintf("chain-audit-%s", audit_id)
	chain_title := fmt.tprintf("Memory Audit (%s) at %s", run_time_range, time.now())
	
	create_chain_res := task_service_create_chain(Task_Chain_Create_Command{
		chain_id                      = strings.clone(audit_chain_id),
		project_id                    = strings.clone(system_project_id),
		title                         = strings.clone(chain_title),
		description                   = strings.clone(PROMPT_AUDIT_CHAIN_DESC),
		coordinator_agent_instance_id = strings.clone(auditor_agent_id),
		author_agent_instance_id     = strings.clone(author),
	})
	if !create_chain_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to create audit chain: %s\"}", create_chain_res.message))
		return
	}

	// 10. Create Task 1: Discover completed chains
	t1_desc := populate_prompt_template(PROMPT_AUDIT_TASK_1, run_time_range, target_chains_json, auditor_instructions)
	defer delete(t1_desc)
	t1_res := task_service_create_task(Task_Create_Command{
		chain_id                      = strings.clone(audit_chain_id),
		project_id                    = strings.clone(system_project_id),
		title                         = strings.clone("1. Discover completed chains"),
		description                   = strings.clone(t1_desc),
		status                        = "planning",
		assignee_agent_instance_id   = strings.clone(auditor_agent_id),
		reviewer_agent_instance_id   = strings.clone(reviewer_agent_id),
		created_by                    = strings.clone(author),
		author_agent_instance_id      = strings.clone(author),
	})
	if !t1_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to create task 1: %s\"}", t1_res.message))
		return
	}
	t1_id := extract_json_string(t1_res.message, "task_id", "")
	defer delete(t1_id)

	// Create Task 2: Filter target chains
	t2_desc := populate_prompt_template(PROMPT_AUDIT_TASK_2, run_time_range, target_chains_json, auditor_instructions)
	defer delete(t2_desc)
	t2_res := task_service_create_task(Task_Create_Command{
		chain_id                      = strings.clone(audit_chain_id),
		project_id                    = strings.clone(system_project_id),
		title                         = strings.clone("2. Filter target chains"),
		description                   = strings.clone(t2_desc),
		status                        = "planning",
		assignee_agent_instance_id   = strings.clone(auditor_agent_id),
		reviewer_agent_instance_id   = strings.clone(reviewer_agent_id),
		depends_on                    = strings.clone(t1_id),
		created_by                    = strings.clone(author),
		author_agent_instance_id      = strings.clone(author),
	})
	if !t2_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to create task 2: %s\"}", t2_res.message))
		return
	}
	t2_id := extract_json_string(t2_res.message, "task_id", "")
	defer delete(t2_id)

	// Create Task 3: Deep analysis of chains
	t3_desc := populate_prompt_template(PROMPT_AUDIT_TASK_3, run_time_range, target_chains_json, auditor_instructions)
	defer delete(t3_desc)
	t3_res := task_service_create_task(Task_Create_Command{
		chain_id                      = strings.clone(audit_chain_id),
		project_id                    = strings.clone(system_project_id),
		title                         = strings.clone("3. Deep analysis of chains"),
		description                   = strings.clone(t3_desc),
		status                        = "planning",
		assignee_agent_instance_id   = strings.clone(auditor_agent_id),
		reviewer_agent_instance_id   = strings.clone(reviewer_agent_id),
		depends_on                    = strings.clone(t2_id),
		created_by                    = strings.clone(author),
		author_agent_instance_id      = strings.clone(author),
	})
	if !t3_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to create task 3: %s\"}", t3_res.message))
		return
	}
	t3_id := extract_json_string(t3_res.message, "task_id", "")
	defer delete(t3_id)

	// Create Task 4: Compile memory recommendations
	t4_desc := populate_prompt_template(PROMPT_AUDIT_TASK_4, run_time_range, target_chains_json, auditor_instructions)
	defer delete(t4_desc)
	t4_res := task_service_create_task(Task_Create_Command{
		chain_id                      = strings.clone(audit_chain_id),
		project_id                    = strings.clone(system_project_id),
		title                         = strings.clone("4. Compile memory recommendations"),
		description                   = strings.clone(t4_desc),
		status                        = "planning",
		assignee_agent_instance_id   = strings.clone(auditor_agent_id),
		reviewer_agent_instance_id   = strings.clone(reviewer_agent_id),
		depends_on                    = strings.clone(t3_id),
		created_by                    = strings.clone(author),
		author_agent_instance_id      = strings.clone(author),
	})
	if !t4_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to create task 4: %s\"}", t4_res.message))
		return
	}
	t4_id := extract_json_string(t4_res.message, "task_id", "")
	defer delete(t4_id)

	// Create Task 5: Propose approved memories
	t5_desc := populate_prompt_template(PROMPT_AUDIT_TASK_5, run_time_range, target_chains_json, auditor_instructions)
	defer delete(t5_desc)
	t5_res := task_service_create_task(Task_Create_Command{
		chain_id                      = strings.clone(audit_chain_id),
		project_id                    = strings.clone(system_project_id),
		title                         = strings.clone("5. Propose approved memories"),
		description                   = strings.clone(t5_desc),
		status                        = "planning",
		assignee_agent_instance_id   = strings.clone(auditor_agent_id),
		reviewer_agent_instance_id   = strings.clone(reviewer_agent_id),
		depends_on                    = strings.clone(t4_id),
		created_by                    = strings.clone(author),
		author_agent_instance_id      = strings.clone(author),
	})
	if !t5_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to create task 5: %s\"}", t5_res.message))
		return
	}
	t5_id := extract_json_string(t5_res.message, "task_id", "")
	defer delete(t5_id)

	// 11. Activate the audit chain! (This promotes Task 1 to ready and initiates auto-promotion flow)
	activate_res := task_service_activate_chain(Task_Chain_Activate_Command{
		chain_id                 = strings.clone(audit_chain_id),
		author_agent_instance_id = strings.clone(author),
	})
	if !activate_res.ok {
		write_response(client, 500, "Internal Server Error", fmt.tprintf("{\"ok\":false,\"message\":\"failed to activate audit chain: %s\"}", activate_res.message))
		return
	}

	// 12. Spawn the Memory Auditor Agent Wrapper!
	if !memory_auditor_start_agent(auditor_agent_id, "memory_auditor", auditor_provider_profile, auditor_model_tier, system_project_id) {
		write_response(client, 500, "Internal Server Error", `{"ok":false,"message":"failed to spawn Memory Auditor agent wrapper"}`)
		return
	}

	// 13. Broadcast WebSocket Event
	audit_start_event_broadcast(audit_id, time_range, target_chains_json)

	// 14. Return Success to Caller
	write_response(client, 200, "OK", fmt.tprintf("{{\"ok\":true,\"audit_id\":\"%s\",\"target_chains_count\":%d,\"audit_task_id\":\"%s\",\"audit_chain_id\":\"%s\"}}", 
		audit_id, len(target_chains), t1_id, audit_chain_id))
}

memory_auditor_start_agent :: proc(agent_instance_id, template_id, provider_profile, model_tier, project_id: string) -> bool {
	config_path := server_config_path
	log_path := wrapper_log_path(agent_instance_id)
	display_name := agent_instance_id

	agent_record_id, final_tier, upsert_ok := agent_record_upsert(agent_instance_id, display_name, template_id, provider_profile, project_id, "", model_tier)
	if !upsert_ok {
		fmt.println("memory_auditor_start_agent: agent_record_upsert failed")
		return false
	}

	agent_token := generate_agent_token()
	registry_add_pending_agent_token(agent_instance_id, agent_token)
	
	ok := launch_wrapper_detached(agent_instance_id, provider_profile, config_path, log_path, agent_token, display_name, final_tier, project_id)
	if !ok {
		fmt.println("memory_auditor_start_agent: launch_wrapper_detached failed")
		return false
	}
	
	fmt.printfln("memory_auditor_start_agent: successfully spawned %s (%s) under token %s", agent_instance_id, template_id, agent_token)
	return true
}

memory_auditor_resolve_pref :: proc(user_id, key: string) -> string {
	pref: User_Preference
	found: bool
	if user_id != "" {
		pref, found = user_pref_db_get(user_id, key)
	} else {
		pref, found = user_pref_db_get_any(key)
	}
	if found {
		return strings.clone(pref.value)
	}
	val, _ := get_preference_default(key)
	return strings.clone(val)
}

delta_unix_ms :: proc(time_range: string) -> i64 {
	switch time_range {
	case "1h":  return 60 * 60 * 1000
	case "24h", "1d": return 24 * 60 * 60 * 1000
	case "7d":  return 7 * 24 * 60 * 60 * 1000
	}
	return 0
}

audit_start_event_broadcast :: proc(audit_id, time_range, target_chains_json: string) {
	payload := fmt.tprintf("{{\"type\":\"audit_start\",\"audit_id\":\"%s\",\"time_range\":\"%s\",\"target_chains\":%s}}", audit_id, time_range, target_chains_json)
	user_client_fanout_all_ws_text(payload)
}

memory_auditor_conclude_audit :: proc(audit_id, status, failure_reason: string) {
	active_run, found := audit_db_get_active_run()
	if !found do return
	defer audit_run_free(active_run)
	
	if active_run.audit_id != audit_id do return // Safety check

	run := active_run
	run.status = strings.clone(status)
	run.completed_at_unix_ms = now_unix_ms()
	run.failure_reason = strings.clone(failure_reason)
	
	if audit_db_update_run(run) {
		fmt.printfln("memory_auditor_conclude_audit: concluded audit %s with status %s", audit_id, status)
		
		// Conclude target task chains in task database
		if status == "completed" {
			targets := parse_json_string_array(active_run.target_chains_json)
			defer {
				for t in targets do delete(t)
				delete(targets)
			}
			for chain_id in targets {
				task_store_update_chain_audit_ts(chain_id, run.completed_at_unix_ms)
			}
		}
	}
	delete(run.status)
	delete(run.failure_reason)

	payload := fmt.tprintf("{{\"type\":\"audit_end\",\"audit_id\":\"%s\",\"status\":\"%s\",\"completed_at_unix_ms\":%d,\"failure_reason\":\"%s\"}}", 
		audit_id, status, now_unix_ms(), failure_reason)
	user_client_fanout_all_ws_text(payload)
}

audit_janitor_tick :: proc() {
	active_run, found := audit_db_get_active_run()
	if !found do return
	defer audit_run_free(active_run)

	now := now_unix_ms()
	elapsed_sec := (now - active_run.started_at_unix_ms) / 1000

	// 1. Max Execution Timeout (configurable, defaults to 10 minutes)
	timeout_min_str := memory_auditor_resolve_pref("", "memory_auditor_timeout_min")
	defer delete(timeout_min_str)
	timeout_min := 10
	if parsed, ok := strconv.parse_int(timeout_min_str); ok {
		timeout_min = parsed
	}
	max_timeout_sec := i64(timeout_min * 60)
	if elapsed_sec >= max_timeout_sec {
		fmt.printfln("AUDIT TIMEOUT: Run %s timed out after %d seconds (limit: %d mins).", active_run.audit_id, elapsed_sec, timeout_min)
		memory_auditor_conclude_audit(active_run.audit_id, "failed", "execution_timeout")
		return
	}

	// 2. Check if the Auditor Agent is stuck/offline/failed startup
	audit_chain_id := fmt.tprintf("chain-audit-%s", active_run.audit_id)
	idx := -1
	task_found := false
	for i in 0..<task_state_count {
		if task_states[i].chain_id == audit_chain_id {
			if task_states[i].status == .Ready || task_states[i].status == .In_Progress {
				idx = i
				task_found = true
				break
			}
		}
	}
	if !task_found {
		return
	}
	
	task_state := task_states[idx]
	assignee := task_state.assignee_agent_instance_id

	if task_state.status == .Ready || task_state.status == .In_Progress {
		agent_idx := agent_record_index_by_instance(assignee)
		if agent_idx >= 0 {
			agent := agents[agent_idx]
			if agent.startup_status == "startup_failed" {
				fmt.printfln("AUDIT FAILED: Auditor agent %s startup failed (%s). Failing run %s.", assignee, agent.startup_reason_code, active_run.audit_id)
				memory_auditor_conclude_audit(active_run.audit_id, "failed", "agent_startup_failed")
				return
			}
			
			// If unclaimed for more than 120 seconds, mark stale
			if task_state.status == .Ready && elapsed_sec >= 120 {
				fmt.printfln("AUDIT FAILED: Auditor agent %s failed to claim task within 120s. Failing run %s.", assignee, active_run.audit_id)
				memory_auditor_conclude_audit(active_run.audit_id, "failed", "agent_startup_stale")
				return
			}

			// If agent went offline during active working, fail run
			if task_state.status == .In_Progress && !agent.connected && elapsed_sec >= 30 {
				fmt.printfln("AUDIT FAILED: Auditor agent %s went offline during execution. Failing run %s.", assignee, active_run.audit_id)
				memory_auditor_conclude_audit(active_run.audit_id, "failed", "agent_went_offline")
				return
			}
		}
	}
}

parse_json_string_array :: proc(json_str: string) -> []string {
	result := make([dynamic]string, context.allocator)
	
	in_quotes := false
	start_idx := -1
	
	for i in 0..<len(json_str) {
		if json_str[i] == '"' {
			if in_quotes {
				element := json_str[start_idx:i]
				append(&result, strings.clone(element))
				in_quotes = false
				start_idx = -1
			} else {
				in_quotes = true
				start_idx = i + 1
			}
		}
	}
	return result[:]
}
