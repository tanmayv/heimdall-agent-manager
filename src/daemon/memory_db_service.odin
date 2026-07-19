package main

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

Memory_Db_Service :: struct {
	db:      sqlite3,
	db_path: string,
}

memory_db: Memory_Db_Service

MEMORY_DB_USER_VERSION :: 5 // remove team/role targeting (memory db is recreated on bump)

memory_db_init :: proc(data_dir: string) -> bool {
	db_dir := fmt.tprintf("%s/memory", data_dir)
	_ = os.make_directory_all(db_dir)

	db_path := fmt.tprintf("%s/memory.db", db_dir)
	memory_db.db_path = strings.clone(db_path)

	rc := sqlite3_open(cstring(raw_data(db_path)), &memory_db.db)
	if rc != SQLITE_OK {
		fmt.println("memory_db_init: sqlite3_open failed:", rc)
		return false
	}

	if !memory_db_run_migrations() {
		fmt.println("memory_db_init: failed to run migrations")
		sqlite3_close(memory_db.db)
		return false
	}

	if !memory_db_seed_core_skills() {
		fmt.println("memory_db_init: failed to seed core skills")
		sqlite3_close(memory_db.db)
		return false
	}

	fmt.println("memory_db_init: database initialized at", db_path)
	return true
}

memory_db_close :: proc() {
	if memory_db.db != nil {
		sqlite3_close(memory_db.db)
		memory_db.db = nil
	}
}

Core_Skill_Seed :: struct {
	memory_id: string,
	title:     string,
	body:      string,
}

CORE_SKILL_METADATA_JSON :: `{"seed":"core-skill","editable":true}`

core_skill_seeds := []Core_Skill_Seed {
	Core_Skill_Seed{
		memory_id = "core-skill-task-workflow",
		title = "task-workflow",
		body = `name: task-workflow
description: Use when starting, resuming, updating, or handing off Heimdall task work. It explains task authority, comments, unresolved items, and review handoff.

# Task workflow
- Start by reading the task chain, the current task, predecessor evidence, and unresolved comments.
- Treat task and participant state as the only source of current responsibility: assignee implements, coordinator routes user-facing decisions, reviewers vote LGTM/NGTM, subscribers observe.
- Keep progress and evidence in task comments; resolve informational comments before handoff.
- Before marking done, list unresolved comments, address or explicitly defer each one, and include changed files plus validation commands in the completion comment.
- Marking done means ready for review, not self-approval.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-review-and-evidence",
		title = "review-and-evidence",
		body = `name: review-and-evidence
description: Use when preparing implementation evidence or reviewing a task. It defines LGTM/NGTM expectations and REQ-ID-based validation.

# Review and evidence
- Cite the REQ-IDs covered by every implementation summary, test report, and review vote.
- A reviewer verifies claimed requirements against code, tests, logs, and artifacts, then votes LGTM or NGTM.
- NGTM feedback must identify the unmet REQ-ID or explicitly state that the issue is a non-REQ nit.
- Prefer one consolidated review comment over many hidden blockers.
- Evidence should include exact file paths, commands, exit status, and known gaps.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-coordinator-playbook",
		title = "coordinator-playbook",
		body = `name: coordinator-playbook
description: Use when the current task or participant state makes you the task-chain coordinator, or when another agent asks you to route a user-facing decision.

# Coordinator playbook
- Own user-facing free-form communication for the chain; acknowledge user messages promptly and state the intended next step.
- Keep the chain description as the canonical design document with REQ-IDs, scope, task plan, validation strategy, and risks.
- Consolidate team questions before asking the user, propose defaults when useful, and avoid blocking on questions the task state already answers.
- Ensure every implementation task has an assignee, blocking reviewer, dependencies, and acceptance criteria tied to REQ-IDs.
- Complete the chain only after approved tasks cover every requirement; final summaries include task IDs, review results, evidence, commits, known gaps, and requirement coverage.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-git-hygiene",
		title = "git-hygiene",
		body = `name: git-hygiene
description: Use when editing a repository, preparing commits, using VCS workspaces, or reporting changed files.

# Git hygiene
- Inspect status before editing and avoid overwriting unrelated user or agent changes.
- Keep diffs scoped to the task; separate unrelated cleanup into follow-up tasks.
- Use exact file paths in updates and completion comments.
- Run formatting or diff checks appropriate for the project before handoff.
- Do not commit, push, merge, or deploy unless the task or coordinator explicitly asks for it.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-contracts-first",
		title = "contracts-first",
		body = `name: contracts-first
description: Use when changing APIs, schemas, wire formats, event stores, task/participant state, config, or CLI contracts.

# Contracts first
- Identify the durable contract before coding: request/response JSON, DB schema, event record, CLI flags, config keys, UI type, or wrapper bootstrap field.
- Update writers, readers, replay/apply paths, tests, and documentation together so old and new surfaces do not diverge.
- Fail closed on deprecated or unknown behavioral fields rather than silently accepting stale contract input.
- Prefer small compatibility adapters at boundaries over scattered string checks in business logic.
- Include contract search proof in completion evidence when removing a field or concept.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-testing-discipline",
		title = "testing-discipline",
		body = `name: testing-discipline
description: Use when deciding what to test, adding regression coverage, or reporting validation for implementation work.

# Testing discipline
- Add or update tests for changed behavior, regressions, and public contract changes.
- Run the smallest focused test first, then the required package build or broader suite for touched components.
- Record commands with exit status and enough output context for reviewers to reproduce failures.
- If a required check cannot run, state why, what risk remains, and which follow-up or environment action would close it.
- For Heimdall daemon, wrapper, and ctl changes, build the affected Nix package before review handoff.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-scaffold-coding-feature",
		title = "scaffold-coding-feature",
		body = `name: scaffold-coding-feature
description: Use when the chain goal is a coding feature, enhancement, refactor, or product change that needs implementation plus review. The coordinator selects this recipe from the goal; the daemon does not select it from a chain kind.

# Coding feature recipe
- Start with one coordinator planning/kickoff task that turns the goal into downstream tasks.
- Create focused implementation tasks assigned through default-use ids such as assignee/worker/coder/tester/specialist, not through a generated roster.
- Add at least one blocking review task/participant for changed behavior; use the configured reviewer default unless the plan explicitly requires user_proxy.
- Add testing/documentation tasks when behavior, contracts, UI, or docs change.
- If a VCS workspace task exists, make implementation tasks that need files depend on it.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-scaffold-coding-bugfix",
		title = "scaffold-coding-bugfix",
		body = `name: scaffold-coding-bugfix
description: Use when the chain goal is a bug fix or regression investigation that should reproduce, fix, test, and review the defect. The coordinator selects this recipe from the goal.

# Coding bugfix recipe
- Create a reproduction or diagnosis task first when the bug is not already understood.
- Create a focused fix task with acceptance criteria tied to the observed failure.
- Create or update regression tests that fail before the fix when practical.
- Gate the fix with blocking review and include evidence for the failing/passing behavior.
- Keep unrelated cleanup out of the bugfix chain unless the coordinator records it as required scope.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-scaffold-research",
		title = "scaffold-research",
		body = `name: scaffold-research
description: Use when the chain goal asks for investigation, analysis, comparison, planning, or a report rather than code changes. The coordinator selects this recipe from the goal.

# Research recipe
- Create one or more research tasks with clear questions, sources, and expected evidence.
- Add synthesis/report tasks when multiple findings must be consolidated for the user.
- Use review for claims that affect product decisions, technical direction, or user-facing recommendations.
- Prefer artifacts for polished reports and keep task comments for workflow evidence.
- Avoid VCS workspace tasks unless the research explicitly requires repository inspection or edits.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-scaffold-solo",
		title = "scaffold-solo",
		body = `name: scaffold-solo
description: Use when the chain goal is intentionally small enough for a single worker-style assignee plus lightweight review. The coordinator selects this recipe from the goal.

# Solo recipe
- Create the minimum downstream task set needed to satisfy the goal, often one assignee task and one review gate.
- Assign implementation through the configured worker/assignee default id; do not create a roster.
- Use user_proxy as reviewer only when the goal or chain policy requires human approval; otherwise use the configured reviewer default.
- Keep dependencies simple and make the coordinator kickoff task document why solo structure is sufficient.
- Escalate to coding-feature or research recipe if scope expands.`,
	},
	Core_Skill_Seed{
		memory_id = "core-skill-vcs-workspace-setup",
		title = "vcs-workspace-setup",
		body = `name: vcs-workspace-setup
description: Use when chain creation or coordinator planning indicates that a VCS workspace is requested. This is an explicit task/skill path, not a chain kind or team scaffold side effect.

# VCS workspace setup
- Ask the user for approval before running VCS commands and show the exact commands you plan to execute.
- Prepare the workspace against the project's directory, vcs_kind, base_ref, and worktree_root anchors when configured.
- Record the actual workspace path, branch or detached state, base ref, and status output in the task evidence.
- If setup cannot complete, keep the chain plan explicit about which downstream tasks are blocked and why.
- Do not encode VCS behavior in a chain kind, generated roster, or hidden daemon scaffold.`,
	},
}

memory_db_seed_core_skill_source_task :: proc(title: string) -> string {
	if strings.has_prefix(title, "scaffold-") || title == "vcs-workspace-setup" do return "task-19f7ae4a44c"
	return "task-19f7ae4a3eb"
}

memory_db_seed_core_skill_evidence :: proc(title: string) -> string {
	if strings.has_prefix(title, "scaffold-") || title == "vcs-workspace-setup" do return "TR-10/TR-11/TR-19 goal-driven chain planning skill seed"
	return "TR-8/TR-9 core skill bootstrap seed"
}

memory_db_seed_core_skills :: proc() -> bool {
	now := router_now_unix_ms()
	for seed, idx in core_skill_seeds {
		if existing, found := memory_db_get_record(seed.memory_id); found {
			memory_record_free(existing)
			continue
		}
		created := now + i64(idx)
		evidence := memory_db_seed_core_skill_evidence(seed.title)
		rec := contracts.Memory_Record{
			memory_id = seed.memory_id,
			proposal_id = fmt.tprintf("proposal_%s", seed.memory_id),
			type = .Skill,
			title = seed.title,
			body = seed.body,
			status = .Active,
			reason = "Seeded core Heimdall workflow skill",
			evidence = evidence,
			metadata_json = CORE_SKILL_METADATA_JSON,
			source_task_id = memory_db_seed_core_skill_source_task(seed.title),
			version = 2,
			created_unix_ms = created,
			updated_unix_ms = created,
		}
		if !memory_db_save_record(rec) do return false
		proposed := contracts.Memory_Event{
			event_id = fmt.tprintf("%s-proposed", seed.memory_id),
			kind = .Memory_Proposed,
			memory_id = seed.memory_id,
			proposal_id = rec.proposal_id,
			reason = rec.reason,
			evidence = rec.evidence,
			author = "system",
			created_unix_ms = created,
		}
		if !memory_db_save_event(proposed) do return false
		approved := contracts.Memory_Event{
			event_id = fmt.tprintf("%s-approved", seed.memory_id),
			kind = .Memory_Approved,
			memory_id = seed.memory_id,
			proposal_id = rec.proposal_id,
			reason = "Seed approved by daemon bootstrap",
			evidence = rec.evidence,
			author = "system",
			created_unix_ms = created + 1,
		}
		if !memory_db_save_event(approved) do return false
	}
	return true
}

memory_db_create_schema :: proc() -> bool {
	schema := `
	CREATE TABLE IF NOT EXISTS memories (
		memory_id TEXT PRIMARY KEY,
		proposal_id TEXT NOT NULL,
		target_project_id TEXT NOT NULL DEFAULT '',
		type TEXT NOT NULL,
		title TEXT NOT NULL,
		body TEXT NOT NULL,
		status TEXT NOT NULL,
		reason TEXT,
		evidence TEXT,
		metadata_json TEXT,
		source_task_id TEXT,
		version INTEGER NOT NULL,
		created_unix_ms INTEGER NOT NULL,
		updated_unix_ms INTEGER NOT NULL,
		target_agent_id TEXT NOT NULL DEFAULT ''
	);
	CREATE INDEX IF NOT EXISTS idx_memories_status ON memories(status);
	CREATE INDEX IF NOT EXISTS idx_memories_targets ON memories(status, target_project_id);
	CREATE INDEX IF NOT EXISTS idx_memories_agent ON memories(status, target_agent_id);
	CREATE INDEX IF NOT EXISTS idx_memories_proposal ON memories(proposal_id);

	CREATE TABLE IF NOT EXISTS memory_events (
		event_id TEXT PRIMARY KEY,
		memory_id TEXT NOT NULL,
		proposal_id TEXT NOT NULL,
		kind TEXT NOT NULL,
		reason TEXT,
		evidence TEXT,
		author TEXT NOT NULL,
		created_unix_ms INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_memory_events_memory ON memory_events(memory_id);
	`

	errmsg: cstring = nil
	rc := sqlite3_exec(memory_db.db, cstring(raw_data(schema)), nil, nil, &errmsg)
	if rc != SQLITE_OK {
		fmt.println("memory_db_create_schema: error:", errmsg)
		if errmsg != nil {
			sqlite3_free(rawptr(errmsg))
		}
		return false
	}
	return true
}

memory_db_run_migrations :: proc() -> bool {
	current_version := db_get_user_version(memory_db.db)
	if current_version != MEMORY_DB_USER_VERSION {
		if !db_execute(memory_db.db, "BEGIN TRANSACTION;") do return false
		if !db_execute(memory_db.db, "DROP TABLE IF EXISTS memory_events;") {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_execute(memory_db.db, "DROP TABLE IF EXISTS memories;") {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !memory_db_create_schema() {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_set_user_version(memory_db.db, MEMORY_DB_USER_VERSION) {
			_ = db_execute(memory_db.db, "ROLLBACK;")
			return false
		}
		if !db_execute(memory_db.db, "COMMIT;") do return false
		return true
	}
	return memory_db_create_schema()
}

memory_db_save_record :: proc(rec: contracts.Memory_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO memories (
		memory_id, proposal_id, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_save_record: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	type_str := memory_type_string_service(rec.type)
	status_str := memory_status_string_service(rec.status)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(rec.memory_id)), i32(len(rec.memory_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(rec.proposal_id)), i32(len(rec.proposal_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(rec.target_project_id)), i32(len(rec.target_project_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(type_str)), i32(len(type_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(rec.title)), i32(len(rec.title)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(rec.body)), i32(len(rec.body)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(status_str)), i32(len(status_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 8, cstring(raw_data(rec.reason)), i32(len(rec.reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 9, cstring(raw_data(rec.evidence)), i32(len(rec.evidence)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 10, cstring(raw_data(rec.metadata_json)), i32(len(rec.metadata_json)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 11, cstring(raw_data(rec.source_task_id)), i32(len(rec.source_task_id)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 12, i64(rec.version))
	sqlite3_bind_int64(stmt, 13, rec.created_unix_ms)
	sqlite3_bind_int64(stmt, 14, rec.updated_unix_ms)
	sqlite3_bind_text(stmt, 15, cstring(raw_data(rec.target_agent_id)), i32(len(rec.target_agent_id)), SQLITE_TRANSIENT)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("memory_db_save_record: step failed:", rc)
		return false
	}
	return true
}

memory_db_save_event :: proc(ev: contracts.Memory_Event) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO memory_events (
		event_id, memory_id, proposal_id, kind, reason, evidence, author, created_unix_ms
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_save_event: prepare failed:", rc)
		return false
	}
	defer sqlite3_finalize(stmt)

	kind_str := memory_event_kind_string_db(ev.kind)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(ev.event_id)), i32(len(ev.event_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 2, cstring(raw_data(ev.memory_id)), i32(len(ev.memory_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 3, cstring(raw_data(ev.proposal_id)), i32(len(ev.proposal_id)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 4, cstring(raw_data(kind_str)), i32(len(kind_str)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 5, cstring(raw_data(ev.reason)), i32(len(ev.reason)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 6, cstring(raw_data(ev.evidence)), i32(len(ev.evidence)), SQLITE_TRANSIENT)
	sqlite3_bind_text(stmt, 7, cstring(raw_data(ev.author)), i32(len(ev.author)), SQLITE_TRANSIENT)
	sqlite3_bind_int64(stmt, 8, ev.created_unix_ms)

	rc = sqlite3_step(stmt)
	if rc != SQLITE_DONE {
		fmt.println("memory_db_save_event: step failed:", rc)
		return false
	}
	return true
}

memory_db_get_record :: proc(memory_id: string) -> (rec: contracts.Memory_Record, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		memory_id, proposal_id, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories WHERE memory_id = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_get_record: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(memory_id)), i32(len(memory_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) == SQLITE_ROW {
		return memory_db_parse_record(stmt), true
	}
	return {}, false
}

memory_db_get_proposal :: proc(proposal_id: string) -> (rec: contracts.Memory_Record, found: bool) {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		memory_id, proposal_id, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories WHERE proposal_id = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_get_proposal: prepare failed:", rc)
		return {}, false
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(proposal_id)), i32(len(proposal_id)), SQLITE_TRANSIENT)
	if sqlite3_step(stmt) == SQLITE_ROW {
		return memory_db_parse_record(stmt), true
	}
	return {}, false
}

memory_db_list_records :: proc(status: contracts.Memory_Status, include_all: bool) -> []contracts.Memory_Record {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		memory_id, proposal_id, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories`
	if !include_all do query = `SELECT
		memory_id, proposal_id, target_project_id, type,
		title, body, status, reason, evidence, metadata_json, source_task_id,
		version, created_unix_ms, updated_unix_ms, target_agent_id
		FROM memories WHERE status = ?`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_list_records: prepare failed:", rc)
		return nil
	}
	defer sqlite3_finalize(stmt)

	if !include_all {
		status_str := memory_status_string_service(status)
		sqlite3_bind_text(stmt, 1, cstring(raw_data(status_str)), i32(len(status_str)), SQLITE_TRANSIENT)
	}

	result := make([dynamic]contracts.Memory_Record, context.allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		append(&result, memory_db_parse_record(stmt))
	}
	return result[:]
}

memory_db_history :: proc(memory_id: string) -> []contracts.Memory_Event {
	stmt: sqlite3_stmt = nil
	query := `SELECT
		event_id, memory_id, proposal_id, kind, reason, evidence, author, created_unix_ms
		FROM memory_events WHERE memory_id = ? ORDER BY created_unix_ms ASC`

	rc := sqlite3_prepare_v2(memory_db.db, cstring(raw_data(query)), -1, &stmt, nil)
	if rc != SQLITE_OK {
		fmt.println("memory_db_history: prepare failed:", rc)
		return nil
	}
	defer sqlite3_finalize(stmt)

	sqlite3_bind_text(stmt, 1, cstring(raw_data(memory_id)), i32(len(memory_id)), SQLITE_TRANSIENT)

	result := make([dynamic]contracts.Memory_Event, context.allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		ev := contracts.Memory_Event{
			event_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
			memory_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
			proposal_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
			kind = memory_event_kind_from_string_db(strings.clone_from_cstring(sqlite3_column_text(stmt, 3))),
			reason = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
			evidence = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
			author = strings.clone_from_cstring(sqlite3_column_text(stmt, 6)),
			created_unix_ms = sqlite3_column_int64(stmt, 7),
		}
		if rec, found := memory_db_get_record(ev.memory_id); found {
			ev.target_agent_id = strings.clone(rec.target_agent_id)
			ev.target_project_id = strings.clone(rec.target_project_id)
			ev.type = rec.type
			ev.title = strings.clone(rec.title)
			ev.body = strings.clone(rec.body)
			ev.status = rec.status
			ev.metadata_json = strings.clone(rec.metadata_json)
			ev.source_task_id = strings.clone(rec.source_task_id)
			ev.version = rec.version
			memory_record_free(rec)
		}
		append(&result, ev)
	}
	return result[:]
}

memory_db_archive_active_expertise :: proc(rec: contracts.Memory_Record, keep_memory_id: string, at_unix_ms: i64) -> bool {
	records := memory_db_list_records(.Active, false)
	defer {
		for other in records do memory_record_free(other)
		delete(records)
	}
	bucket := memory_expertise_bucket_key(rec)
	defer delete(bucket)
	for other in records {
		if other.memory_id == keep_memory_id do continue
		if other.type != .Expertise do continue
		other_bucket := memory_expertise_bucket_key(other)
		matches := other_bucket == bucket
		delete(other_bucket)
		if !matches do continue
		if found, ok := memory_db_get_record(other.memory_id); ok {
			found.status = .Archived
			found.version += 1
			found.updated_unix_ms = at_unix_ms
			if !memory_db_save_record(found) {
				memory_record_free(found)
				return false
			}
			memory_record_free(found)
		}
	}
	return true
}

memory_db_parse_record :: proc(stmt: sqlite3_stmt) -> contracts.Memory_Record {
	type_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 3))
	status_str := strings.clone_from_cstring(sqlite3_column_text(stmt, 6))
	type_val, _ := memory_type_parse(type_str)
	status_val, _ := memory_status_parse(status_str)
	delete(type_str)
	delete(status_str)

	return contracts.Memory_Record{
		memory_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 0)),
		proposal_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 1)),
		target_project_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 2)),
		type = type_val,
		title = strings.clone_from_cstring(sqlite3_column_text(stmt, 4)),
		body = strings.clone_from_cstring(sqlite3_column_text(stmt, 5)),
		status = status_val,
		reason = strings.clone_from_cstring(sqlite3_column_text(stmt, 7)),
		evidence = strings.clone_from_cstring(sqlite3_column_text(stmt, 8)),
		metadata_json = strings.clone_from_cstring(sqlite3_column_text(stmt, 9)),
		source_task_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 10)),
		version = int(sqlite3_column_int64(stmt, 11)),
		created_unix_ms = sqlite3_column_int64(stmt, 12),
		updated_unix_ms = sqlite3_column_int64(stmt, 13),
		target_agent_id = strings.clone_from_cstring(sqlite3_column_text(stmt, 14)),
	}
}

memory_record_free :: proc(rec: contracts.Memory_Record) {
	delete(rec.memory_id)
	delete(rec.proposal_id)
	delete(rec.target_agent_id)
	delete(rec.target_project_id)
	delete(rec.title)
	delete(rec.body)
	delete(rec.reason)
	delete(rec.evidence)
	delete(rec.metadata_json)
	delete(rec.source_task_id)
}

memory_event_free :: proc(ev: contracts.Memory_Event) {
	delete(ev.event_id)
	delete(ev.memory_id)
	delete(ev.proposal_id)
	delete(ev.target_agent_id)
	delete(ev.target_project_id)
	delete(ev.title)
	delete(ev.body)
	delete(ev.reason)
	delete(ev.evidence)
	delete(ev.metadata_json)
	delete(ev.author)
	delete(ev.source_task_id)
}

memory_event_kind_string_db :: proc(kind: contracts.Memory_Event_Kind) -> string {
	switch kind {
	case .Memory_Proposed: return "Memory_Proposed"
	case .Memory_Approved: return "Memory_Approved"
	case .Memory_Rejected: return "Memory_Rejected"
	case .Memory_Archived: return "Memory_Archived"
	}
	return "Memory_Proposed"
}

memory_event_kind_from_string_db :: proc(value: string) -> contracts.Memory_Event_Kind {
	switch value {
	case "Memory_Approved": return .Memory_Approved
	case "Memory_Rejected": return .Memory_Rejected
	case "Memory_Archived": return .Memory_Archived
	case: return .Memory_Proposed
	}
}
