package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

Agent_Template_Db_Service :: struct {
	db: sqlite3,
	db_path: string,
}

agent_template_db: Agent_Template_Db_Service

agent_template_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/templates", data_dir)
	os.make_directory(db_dir)
	agent_template_db.db_path = strings.clone(fmt.tprintf("%s/templates.db", db_dir))
	
	stmt: sqlite3 = nil
	rc := sqlite3_open(cstring(raw_data(agent_template_db.db_path)), &stmt)
	if rc != SQLITE_OK {
		fmt.println("agent_template_db_init: sqlite3_open failed:", rc)
		return false
	}
	agent_template_db.db = stmt

	if !agent_template_db_create_schema() {
		fmt.println("agent_template_db_init: failed to create schema")
		sqlite3_close(agent_template_db.db)
		return false
	}

	fmt.println("agent_template_db_init: database initialized at", agent_template_db.db_path)
	
	// Seed default templates if the table is empty!
	seed_default_templates_if_empty()
	
	return true
}

agent_template_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS agent_templates (
		template_id TEXT PRIMARY KEY,
		display_name TEXT NOT NULL,
		persona TEXT NOT NULL,
		instructions TEXT NOT NULL,
		role_hint TEXT NOT NULL,
		parent_template_id TEXT NOT NULL,
		default_provider_profile TEXT NOT NULL,
		bootstrap_defaults TEXT NOT NULL,
		suggested_model_tier TEXT NOT NULL DEFAULT 'normal',
		memory_templates TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		updated_unix_ms INTEGER NOT NULL,
		archived_at_unix_ms INTEGER NOT NULL DEFAULT 0
	);
	`
	errmsg: cstring = nil
	rc := sqlite3_exec(agent_template_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		if errmsg != nil {
			fmt.println("agent_template_db_create_schema: error:", errmsg)
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

agent_template_db_save :: proc(rec: Agent_Template_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO agent_templates (
		template_id, display_name, persona, instructions, role_hint,
		parent_template_id, default_provider_profile, bootstrap_defaults, suggested_model_tier,
		memory_templates, created_unix_ms, updated_unix_ms, archived_at_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(agent_template_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("agent_template_db_save: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	// Serialize memory_templates as comma-separated string
	mem_b := strings.builder_make()
	for i in 0..<rec.memory_template_count {
		if i > 0 do strings.write_string(&mem_b, ",")
		strings.write_string(&mem_b, rec.memory_templates[i])
	}
	mem_str := strings.to_string(mem_b)

	task_db_bind_text(stmt, 1, rec.template_id)
	task_db_bind_text(stmt, 2, rec.display_name)
	task_db_bind_text(stmt, 3, rec.persona)
	task_db_bind_text(stmt, 4, rec.instructions)
	task_db_bind_text(stmt, 5, rec.role_hint)
	task_db_bind_text(stmt, 6, rec.parent_template_id)
	task_db_bind_text(stmt, 7, rec.default_provider_profile)
	task_db_bind_text(stmt, 8, rec.bootstrap_defaults)
	task_db_bind_text(stmt, 9, rec.suggested_model_tier)
	task_db_bind_text(stmt, 10, mem_str)
	sqlite3_bind_int64(stmt, 11, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 12, rec.updated_unix_ms)
	sqlite3_bind_int64(stmt, 13, rec.archived_at_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.printf("agent_template_db_save: step failed: %d (%s)\n", rc, sqlite3_errmsg(agent_template_db.db))
		return false
	}
	return true
}

agent_template_db_load_all :: proc() -> bool {
	agent_template_record_count = 0

	stmt: sqlite3_stmt = nil
	query := `SELECT 
		template_id, display_name, persona, instructions, role_hint,
		parent_template_id, default_provider_profile, bootstrap_defaults, suggested_model_tier,
		memory_templates, created_unix_ms, updated_unix_ms, archived_at_unix_ms
		FROM agent_templates`

	rc := sqlite3_prepare_v2(agent_template_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("agent_template_db_load_all: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	for sqlite3_step(stmt) == SQLITE_ROW {
		if agent_template_record_count >= AGENT_TEMPLATE_MAX_RECORDS do break
		rec := &agent_template_records[agent_template_record_count]
		
		rec.template_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0))
		rec.display_name = strings.clone_from_cstring(sqlite3_column_text(stmt, 1))
		rec.persona = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
		rec.instructions = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
		rec.role_hint = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
		rec.parent_template_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
		rec.default_provider_profile = strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
		rec.bootstrap_defaults = strings.clone_from_cstring(sqlite3_column_text(stmt, 7))
		rec.suggested_model_tier = strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
		
		mem_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 9))
		if mem_str != "" {
			parts := strings.split(mem_str, ",")
			rec.memory_template_count = 0
			for part in parts {
				if rec.memory_template_count >= AGENT_TEMPLATE_MAX_MEMORY_TEMPLATES do break
				if part != "" {
					rec.memory_templates[rec.memory_template_count] = strings.clone(part)
					rec.memory_template_count += 1
				}
			}
		} else {
			rec.memory_template_count = 0
		}
		
		rec.created_unix_ms = sqlite3_column_int64(stmt, 10)
		rec.updated_unix_ms = sqlite3_column_int64(stmt, 11)
		rec.archived_at_unix_ms = sqlite3_column_int64(stmt, 12)
		
		agent_template_record_count += 1
	}

	return true
}

agent_template_exists :: proc(template_id: string) -> bool {
	stmt: sqlite3_stmt = nil
	query := "SELECT COUNT(*) FROM agent_templates WHERE template_id = ?"
	rc := sqlite3_prepare_v2(agent_template_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false
	defer sqlite3_finalize(stmt)
	sqlite3_bind_text(stmt, 1, cstring(raw_data(template_id)), i32(len(template_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) == SQLITE_ROW {
		return sqlite3_column_int64(stmt, 0) > 0
	}
	return false
}

seed_default_templates_if_empty :: proc() {
	fmt.println("agent_template_db: checking and seeding default templates...")
	now := router_now_unix_ms()
	
	// 1. Planner
	if !agent_template_exists("planner") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "planner",
			display_name = "Planner",
			role_hint = "planning",
			suggested_model_tier = "smart",
			persona = "You are an expert strategic planner and systems architect. Your mindset is focused on breaking down complex goals into logical, sequential, and highly structured task chains. You prioritize dependency management, risk mitigation, and clear acceptance criteria.",
			instructions = "When given a goal, analyze the requirements thoroughly. Propose a structured plan. Define a task chain with clear, discrete tasks. Each task must have precise acceptance criteria, a designated assignee role, and explicit dependencies. Always structure your output logically.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}

	// 2. Lead
	if !agent_template_exists("lead") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "lead",
			display_name = "Tech Lead",
			role_hint = "leading",
			suggested_model_tier = "smart",
			persona = "You are a seasoned Tech Lead and engineering coordinator. Your mindset is focused on overall system architecture, code quality standards, coordinating multiple agent roles, and ensuring the task chain progresses smoothly to completion.",
			instructions = "Act as the coordinator for the task chain. Monitor the progress of all assignees. Review task outputs, coordinate LGTM approvals, and ensure that completed work integrates seamlessly. When all tasks are complete, compile the final summary with verifiable commits and file paths, and propose the quality rating.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}

	// 3. Reviewer
	if !agent_template_exists("reviewer") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "reviewer",
			display_name = "Reviewer",
			role_hint = "reviewing",
			suggested_model_tier = "smart",
			persona = "You are an exceptionally thorough code reviewer and quality assurance engineer. Your mindset is critical, detail-oriented, and focused on correctness, security, performance, edge cases, and adherence to style guidelines.",
			instructions = "Review all submitted code changes and task outputs. Inspect file diffs, verify test coverage, and check for potential bugs or security vulnerabilities. Provide constructive feedback. Only grant a LGTM ('lgtm' or 'approved') when the work is completely verified and matches all acceptance criteria.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}

	// 4. Coder
	if !agent_template_exists("coder") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "coder",
			display_name = "Coder",
			role_hint = "coding",
			suggested_model_tier = "normal",
			persona = "You are a highly efficient, clean-coding software engineer. Your mindset is focused on writing elegant, readable, well-commented, and robust code that solves the specified problem while maintaining documentation integrity.",
			instructions = "Implement the requested features or bug fixes. Adhere strictly to the project's style guidelines. Write unit tests for all new logic. Maintain existing comments and docstrings. Explain your implementation decisions clearly in your task completion notes.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}

	// 5. Tester
	if !agent_template_exists("tester") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "tester",
			display_name = "Tester",
			role_hint = "testing",
			suggested_model_tier = "normal",
			persona = "You are a dedicated test engineer and automation specialist. Your mindset is focused on breaking things, finding edge cases, achieving high test coverage, and ensuring regression safety.",
			instructions = "Write comprehensive unit, integration, or regression tests for the codebase. Identify edge cases, boundary conditions, and error paths. Verify that tests run successfully and report coverage metrics. Document any bugs or failures discovered during testing.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}

	// 6. Memory Auditor
	if !agent_template_exists("memory_auditor") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "memory_auditor",
			display_name = "Memory Auditor",
			role_hint = "auditing",
			suggested_model_tier = "smart",
			persona = "You are an expert agent memory auditor and cognitive optimizer. Your mindset is analytical, reflective, and focused on continuous learning. You specialize in analyzing historical task chains, extracting key lessons learned, expertise, and best practices, and formulating them into structured memories that help other agents perform better next time.",
			instructions = "Analyze successfully completed task chains. Inspect the final summaries, git commits, and results. Extract core expertise, guidelines, and lessons learned. Formulate these findings into structured agent memories (e.g. facts, expertise, or skills) and propose them via the memory proposal system so the participating agents can inherit them.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}

	// 7. Memory Reviewer
	if !agent_template_exists("memory_reviewer") {
		agent_template_db_save(Agent_Template_Record{
			template_id = "memory_reviewer",
			display_name = "Memory Reviewer",
			role_hint = "reviewing",
			suggested_model_tier = "smart",
			persona = "You are an expert agent cognitive reviewer and memory curator. Your mindset is critical, precise, and focused on quality control, structural clarity, and relevance. You specialize in auditing proposed agent memories, checking them for factual correctness, formatting consistency, duplication, and absolute clarity before they are presented to human operators for final approval.",
			instructions = "Review all pending memory proposals for the target agents and projects. Audit each proposal for: 1. Duplication (does this agent already know this?). 2. Factual Accuracy (is it supported by the task chain evidence?). 3. Structural Clarity and Formatting (is the title descriptive and is the body actionable?). Refine, merge, or annotate proposals with comments to help the human curator make fast, high-fidelity decisions.",
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
		})
	}
}
