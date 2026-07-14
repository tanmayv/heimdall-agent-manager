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

	if !agent_template_db_run_migrations() {
		fmt.println("agent_template_db_init: failed to run migrations")
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
		description TEXT NOT NULL DEFAULT '',
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
		archived_at_unix_ms INTEGER NOT NULL DEFAULT 0,
		is_customized INTEGER DEFAULT 0
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
		template_id, display_name, description, persona, instructions, role_hint,
		parent_template_id, default_provider_profile, bootstrap_defaults, suggested_model_tier,
		memory_templates, created_unix_ms, updated_unix_ms, archived_at_unix_ms, is_customized
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

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
	task_db_bind_text(stmt, 3, rec.description)
	task_db_bind_text(stmt, 4, rec.persona)
	task_db_bind_text(stmt, 5, rec.instructions)
	task_db_bind_text(stmt, 6, rec.role_hint)
	task_db_bind_text(stmt, 7, rec.parent_template_id)
	task_db_bind_text(stmt, 8, rec.default_provider_profile)
	task_db_bind_text(stmt, 9, rec.bootstrap_defaults)
	task_db_bind_text(stmt, 10, rec.suggested_model_tier)
	task_db_bind_text(stmt, 11, mem_str)
	sqlite3_bind_int64(stmt, 12, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 13, rec.updated_unix_ms)
	sqlite3_bind_int64(stmt, 14, rec.archived_at_unix_ms)
	sqlite3_bind_int64(stmt, 15, rec.is_customized ? 1 : 0)

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
		template_id, display_name, description, persona, instructions, role_hint,
		parent_template_id, default_provider_profile, bootstrap_defaults, suggested_model_tier,
		memory_templates, created_unix_ms, updated_unix_ms, archived_at_unix_ms, is_customized
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
		rec.description = strings.clone_from_cstring(sqlite3_column_text(stmt, 2))
		rec.persona = strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
		rec.instructions = strings.clone_from_cstring(sqlite3_column_text(stmt, 4))
		rec.role_hint = strings.clone_from_cstring(sqlite3_column_text(stmt, 5))
		rec.parent_template_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
		rec.default_provider_profile = strings.clone_from_cstring(sqlite3_column_text(stmt, 7))
		rec.bootstrap_defaults = strings.clone_from_cstring(sqlite3_column_text(stmt, 8))
		rec.suggested_model_tier = strings.clone_from_cstring(sqlite3_column_text(stmt, 9))
		
		mem_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 10))
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
		
		rec.created_unix_ms = sqlite3_column_int64(stmt, 11)
		rec.updated_unix_ms = sqlite3_column_int64(stmt, 12)
		rec.archived_at_unix_ms = sqlite3_column_int64(stmt, 13)
		rec.is_customized = sqlite3_column_int64(stmt, 14) != 0
		
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
	if exists, customized := agent_template_get_customized_status("planner"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "planner",
			display_name = "Planner",
			description = "Use this template for analytical strategist agents that decompose goals, map dependencies, and draft execution schedules.",
			role_hint = "planning",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/planner_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/planner_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 2. Lead
	if exists, customized := agent_template_get_customized_status("lead"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "lead",
			display_name = "Tech Lead",
			description = "Use this template for coordinator agents that delegate tasks, track progress, resolve blockers, and consolidate results.",
			role_hint = "leading",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/lead_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/lead_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 3. Reviewer
	if exists, customized := agent_template_get_customized_status("reviewer"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "reviewer",
			display_name = "Reviewer",
			description = "Use this template for quality gatekeeper agents that audit code readability, correctness, and style standards.",
			role_hint = "reviewing",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/reviewer_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/reviewer_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 4. Coder
	if exists, customized := agent_template_get_customized_status("coder"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "coder",
			display_name = "Coder",
			description = "Use this template for implementation agents that write functional code, run tests, and address reviewer feedback.",
			role_hint = "coding",
			suggested_model_tier = "normal",
			persona = strings.trim_space(#load("../prompts/coder_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/coder_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 5. Researcher
	if exists, customized := agent_template_get_customized_status("researcher"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "researcher",
			display_name = "Researcher",
			description = "Use this template for evidence-driven investigation, RCA, and synthesis agents that answer questions without owning production code changes.",
			role_hint = "researcher",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/researcher_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/researcher_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 6. Tester
	if exists, customized := agent_template_get_customized_status("tester"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "tester",
			display_name = "Tester",
			description = "Use this template for validation agents that design test cases, execute suites, and report bugs.",
			role_hint = "testing",
			suggested_model_tier = "normal",
			persona = strings.trim_space(#load("../prompts/tester_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/tester_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 7. Memory Auditor
	if exists, customized := agent_template_get_customized_status("memory_auditor"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "memory_auditor",
			display_name = "Memory Auditor",
			description = "Use this template for reflective agents that analyze task histories and logs to extract reusable learnings.",
			role_hint = "auditing",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/memory_auditor_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/memory_auditor_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 8. Memory Reviewer
	if exists, customized := agent_template_get_customized_status("memory_reviewer"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "memory_reviewer",
			display_name = "Memory Reviewer",
			description = "Use this template for decision-making agents that inspect and approve/reject proposed memories.",
			role_hint = "reviewing",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/memory_reviewer_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/memory_reviewer_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 9. Guide
	if exists, customized := agent_template_get_customized_status("guide"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "guide",
			display_name = "Heimdall Guide",
			description = "Use this singleton global template for Heimdall product guidance, daemon/UI diagnostics, and operator support.",
			role_hint = "guiding",
			suggested_model_tier = "smart",
			persona = strings.trim_space(#load("../prompts/guide_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/guide_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 10. Specialist
	if exists, customized := agent_template_get_customized_status("specialist"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "specialist",
			display_name = "Specialist",
			description = "Use this template for specialist service agents that act as domain experts, answering requester queries via task comments.",
			role_hint = "specialist",
			suggested_model_tier = "normal",
			persona = strings.trim_space(#load("../prompts/specialist_persona.md", string)),
			instructions = strings.trim_space(#load("../prompts/specialist_instructions.md", string)),
			default_provider_profile = "",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}
}

agent_template_get_customized_status :: proc(template_id: string) -> (exists: bool, customized: bool) {
	stmt: sqlite3_stmt = nil
	query := "SELECT is_customized FROM agent_templates WHERE template_id = ?"
	rc := sqlite3_prepare_v2(agent_template_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK do return false, false
	defer sqlite3_finalize(stmt)
	
	sqlite3_bind_text(stmt, 1, cstring(raw_data(template_id)), i32(len(template_id)), SQLITE_TRANSIENT)
	
	if sqlite3_step(stmt) == SQLITE_ROW {
		customized = sqlite3_column_int64(stmt, 0) != 0
		return true, customized
	}
	return false, false
}

TEMPLATE_DB_SCHEMA_VERSION :: 2 // Version 2 adds 'description' column

agent_template_db_run_migrations :: proc() -> bool {
	current_version := db_get_user_version(agent_template_db.db)
	
	if current_version < 1 {
		fmt.println("DB: Migrating templates.db to version 1 (adding is_customized)...")
		if !db_execute(agent_template_db.db, "BEGIN TRANSACTION;") do return false
		
		if !db_has_column(agent_template_db.db, "agent_templates", "is_customized") {
			migrate_query := "ALTER TABLE agent_templates ADD COLUMN is_customized INTEGER DEFAULT 0"
			if !db_execute(agent_template_db.db, migrate_query) {
				_ = db_execute(agent_template_db.db, "ROLLBACK;")
				return false
			}
		} else {
			fmt.println("DB: Column 'is_customized' already exists in 'agent_templates', skipping ALTER TABLE.")
		}
		
		if !db_set_user_version(agent_template_db.db, 1) {
			_ = db_execute(agent_template_db.db, "ROLLBACK;")
			return false
		}
		
		if !db_execute(agent_template_db.db, "COMMIT;") do return false
		fmt.println("DB: Migrated templates.db to version 1 successfully.")
	}

	if current_version < 2 {
		fmt.println("DB: Migrating templates.db to version 2 (adding description)...")
		if !db_execute(agent_template_db.db, "BEGIN TRANSACTION;") do return false
		
		if !db_has_column(agent_template_db.db, "agent_templates", "description") {
			migrate_query := "ALTER TABLE agent_templates ADD COLUMN description TEXT NOT NULL DEFAULT ''"
			if !db_execute(agent_template_db.db, migrate_query) {
				_ = db_execute(agent_template_db.db, "ROLLBACK;")
				return false
			}
		} else {
			fmt.println("DB: Column 'description' already exists in 'agent_templates', skipping ALTER TABLE.")
		}
		
		if !db_set_user_version(agent_template_db.db, 2) {
			_ = db_execute(agent_template_db.db, "ROLLBACK;")
			return false
		}
		
		if !db_execute(agent_template_db.db, "COMMIT;") do return false
		fmt.println("DB: Migrated templates.db to version 2 successfully.")
	}
	
	return true
}
