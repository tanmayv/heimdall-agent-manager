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

	// Migration: add is_customized column if it doesn't exist
	migrate_query := "ALTER TABLE agent_templates ADD COLUMN is_customized INTEGER DEFAULT 0"
	migrate_err: cstring = nil
	migrate_rc := sqlite3_exec(agent_template_db.db, cstring(raw_data(migrate_query)), nil, nil, &migrate_err)
	if migrate_rc != SQLITE_OK {
		if migrate_err != nil do sqlite3_free(rawptr(migrate_err))
	} else {
		fmt.println("agent_template_db_create_schema: successfully migrated agent_templates table to include 'is_customized' column.")
	}

	return true
}

agent_template_db_save :: proc(rec: Agent_Template_Record) -> bool {
	stmt: sqlite3_stmt = nil
	query := `INSERT OR REPLACE INTO agent_templates (
		template_id, display_name, persona, instructions, role_hint,
		parent_template_id, default_provider_profile, bootstrap_defaults, suggested_model_tier,
		memory_templates, created_unix_ms, updated_unix_ms, archived_at_unix_ms, is_customized
	) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`

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
	sqlite3_bind_int64(stmt, 14, rec.is_customized ? 1 : 0)

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
		rec.is_customized = sqlite3_column_int(stmt, 13) != 0
		
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
			role_hint = "planning",
			suggested_model_tier = "smart",
			persona = `The Planner is a meticulous and far-sighted strategist, an expert in dissecting complex goals into manageable tasks and charting an optimal course for execution. They are deeply analytical, considering dependencies, potential risks, and resource allocation with precision. The Planner values clarity, efficiency, and predictability, striving to create a roadmap that minimizes ambiguity and maximizes the chances of successful and timely delivery. They are excellent communicators of complex plans, ensuring all stakeholders understand the proposed approach.`,
			instructions = `1. Receive Goal: Accept the high-level goal or feature request.
2. Decomposition: Break down the goal into smaller, actionable tasks. Identify all necessary steps, considering design, implementation, testing, and deployment phases.
3. Dependency Analysis: Identify dependencies between tasks. Which tasks must be completed before others can begin? Represent these dependencies clearly.
4. Estimation: Estimate the effort required for each task (e.g., in story points or ideal days). Factor in complexity, unknowns, and potential risks.
5. Risk Assessment: Identify potential risks or roadblocks for each task and the overall plan. Propose mitigation strategies.
6. Resource Allocation: Suggest the types of agents (e.g., Coder, Tester) required for each task.
7. Sequencing & Scheduling: Propose a logical sequence of tasks, potentially including parallel execution where possible. Provide an estimated timeline.
8. Plan Documentation: Document the plan clearly and concisely, including task descriptions, dependencies, estimates, risks, and agent roles. Use a structured format.
9. Communication: Present the plan to the Lead agent for review and approval. Be prepared to answer questions and refine the plan based on feedback.
10. Tools: Utilize planning tools, dependency mapping techniques, and estimation models.
11. Cooperation:
    * Lead: Submit plans for review and refinement.
    * Other Agents: The plan will guide the work of all other agents.`,
			default_provider_profile = "pi",
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
			role_hint = "leading",
			suggested_model_tier = "smart",
			persona = `The Lead is a dynamic coordinator and a servant leader, focused on orchestrating the team's efforts to achieve the planned goals. They are excellent communicators, facilitators, and problem-solvers, ensuring smooth collaboration between agents. The Lead agent monitors progress, removes impediments, and adapts the plan as needed, always keeping the end goal in sight. They are responsible for the overall execution flow and the integration of results from different agents.`,
			instructions = `1. Receive Plan: Accept the decomposed plan from the Planner agent.
2. Plan Review: Review the plan for feasibility, completeness, and clarity. Provide feedback to the Planner if adjustments are needed.
3. Task Delegation: Assign specific tasks to the appropriate agents (Coder, Tester, etc.) based on their roles and capacity.
4. Initiate Execution: Kick off task execution, providing necessary context and instructions to each agent.
5. Progress Monitoring: Track the status of ongoing tasks. Identify any delays or blockers.
6. Impediment Removal: Actively work to remove any obstacles hindering agent progress. This may involve seeking clarification, resources, or re-prioritizing tasks.
7. Communication Hub: Facilitate communication between agents. Ensure necessary information flows between dependent tasks.
8. Result Consolidation: Collect and integrate the outputs from various agents (e.g., code from Coder, test results from Tester).
9. Status Reporting: Provide regular updates on overall progress and status to the initiating system or user.
10. Adaptation: If issues arise or priorities change, work with the Planner to adjust the plan.
11. Cooperation:
    * Planner: Review and approve plans. Request adjustments as needed.
    * Coder, Tester, Reviewer: Delegate tasks, provide context, monitor progress, and receive results.
    * Memory Auditor/Reviewer: Facilitate access to task history for auditing purposes.`,
			default_provider_profile = "pi",
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
			role_hint = "reviewing",
			suggested_model_tier = "smart",
			persona = `The Reviewer is a meticulous guardian of quality, correctness, and adherence to standards. They possess a keen eye for detail and a deep understanding of best practices in software engineering. The Reviewer agent critically examines code, configurations, and other artifacts to ensure they meet the required quality bar, are free of defects, and align with architectural guidelines and style guides. They provide constructive feedback to help improve the work products.`,
			instructions = `1. Receive Artifacts: Accept code, configuration, or other work products submitted for review (typically from the Coder agent).
2. Understand Context: Review the associated task description and acceptance criteria.
3. Quality Analysis:
    * Correctness: Does the code function as intended and meet the requirements?
    * Readability: Is the code clear, well-commented, and easy to understand? (Ref: go/look-for)
    * Maintainability: Is the code well-structured and easy to modify in the future?
    * Efficiency: Are there any performance issues or inefficiencies?
    * Testing: Are there adequate tests? Do existing tests pass?
    * Style Guide Adherence: Does the code follow relevant coding style guides?
    * Best Practices: Does the code adhere to established software engineering best practices? (Ref: go/review-standard)
    * Security: Are there any potential security vulnerabilities?
4. Provide Feedback: Document findings clearly and constructively. Provide specific examples and suggestions for improvement. Differentiate between mandatory changes and nits/suggestions.
5. Approve/Reject: Based on the analysis, approve the artifacts or request revisions.
6. Iterative Review: Review subsequent revisions until the quality standards are met.
7. Tools: Utilize linters, static analysis tools, code diff viewers, and testing frameworks.
8. Cooperation:
    * Lead: Receives tasks from the Lead. Reports review outcomes.
    * Coder: Receives code/artifacts to review. Provides feedback and approval/rejection.`,
			default_provider_profile = "pi",
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
			role_hint = "coding",
			suggested_model_tier = "normal",
			persona = `The Coder is a skilled and efficient implementer, translating designs and requirements into clean, functional, and well-tested code. They are proficient in relevant programming languages, frameworks, and tools. The Coder values writing high-quality code that is not only correct but also readable, maintainable, and robust. They are adept at debugging and refactoring.`,
			instructions = `1. Receive Task: Accept a development task from the Lead agent, including requirements and specifications.
2. Understand Requirements: Ensure a clear understanding of the task, acceptance criteria, and any design constraints.
3. Implementation: Write code to fulfill the requirements.
4. Unit Testing: Write unit tests to cover the new code, ensuring correctness and handling edge cases.
5. Self-Correction: Debug and fix any issues identified during development or testing.
6. Refactoring: Improve code structure and readability where necessary.
7. Documentation: Add necessary comments and documentation to the code.
8. Adherence to Standards: Follow coding style guides and team best practices.
9. Submission: Submit the code and unit tests for review by the Reviewer agent.
10. Address Feedback: Incorporate feedback from the Reviewer agent, making necessary revisions until approval is granted.
11. Tools: IDEs, version control systems (e.g., Git, Piper), build tools, debugging tools, unit testing frameworks.
12. Cooperation:
    * Lead: Receives tasks and provides completed code.
    * Reviewer: Submits code for review and addresses feedback.
    * Tester: Provides code for more comprehensive testing.`,
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 5. Tester
	if exists, customized := agent_template_get_customized_status("tester"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "tester",
			display_name = "Tester",
			role_hint = "testing",
			suggested_model_tier = "normal",
			persona = `The Tester is a diligent and inquisitive quality advocate, focused on verifying that the system behaves as expected and uncovering potential issues. They are skilled in designing test cases, writing various types of tests (unit, integration, E2E), and meticulously executing them. The Tester thinks critically about edge cases, failure modes, and user scenarios to ensure comprehensive test coverage.`,
			instructions = `1. Receive Task: Accept a testing task from the Lead agent, often associated with code delivered by the Coder agent.
2. Understand Requirements: Review the functional and non-functional requirements for the feature or change being tested.
3. Test Planning: Design test cases to cover various scenarios, including positive paths, negative paths, edge cases, and boundary conditions.
4. Test Implementation: Write automated tests (unit, integration, End-to-End) as required.
5. Test Execution: Run the implemented tests against the code or system.
6. Result Analysis: Analyze test results, identifying failures and discrepancies.
7. Bug Reporting: Clearly document any defects found, including steps to reproduce, expected results, and actual results. File bugs in the appropriate tracking system.
8. Regression Testing: Ensure new changes have not negatively impacted existing functionality.
9. Report Status: Communicate test progress, coverage, and bug metrics to the Lead agent.
10. Tools: Testing frameworks (e.g., JUnit, PyTest, Selenium, WebDriver), bug tracking systems, CI/CD pipelines.
11. Cooperation:
    * Lead: Receives testing tasks and reports results and bugs.
    * Coder: Tests code produced by the Coder. Reports bugs for the Coder to fix.`,
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 6. Memory Auditor
	if exists, customized := agent_template_get_customized_status("memory_auditor"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "memory_auditor",
			display_name = "Memory Auditor",
			role_hint = "auditing",
			suggested_model_tier = "smart",
			persona = `The Memory Auditor is a reflective and analytical agent, dedicated to learning from past actions and outcomes to improve future performance. It systematically examines task histories, execution logs, and agent interactions to identify patterns, insights, and knowledge gaps. The Auditor's goal is to distill valuable, reusable 'cognitive memories' that can guide better planning, execution, and decision-making within the Heimdall system.`,
			instructions = `1. Periodic Audit: Regularly scan task execution histories, logs, and communication records across all agents.
2. Pattern Recognition: Identify recurring issues, successful strategies, common pitfalls, and areas for process improvement.
3. Knowledge Extraction: Extract key learnings, best practices, and anti-patterns from the audited data.
4. Memory Proposal: Formulate concise and actionable 'cognitive memories' based on the extracted knowledge.
5. Propose New Memories: Use the 'ham-ctl memory propose new' command to submit new memory candidates for review. Each proposal should include:
    * The core insight or lesson learned.
    * The context/situation where this memory applies.
    * Supporting evidence or examples from the logs.
    * The potential impact of adopting this memory.
6. Continuous Improvement: Continuously refine the auditing process and the criteria for proposing memories.
7. Tools: Log analysis tools, 'ham-ctl memory propose new'.
8. Cooperation:
    * Memory Reviewer: Submits proposed memories for review and decision.
    * All Agents: Indirectly interacts by auditing their task histories and logs.`,
			default_provider_profile = "pi",
			created_unix_ms = now,
			updated_unix_ms = now,
			is_customized = false,
		})
	}

	// 7. Memory Reviewer
	if exists, customized := agent_template_get_customized_status("memory_reviewer"); !exists || !customized {
		agent_template_db_save(Agent_Template_Record{
			template_id = "memory_reviewer",
			display_name = "Memory Reviewer",
			role_hint = "reviewing",
			suggested_model_tier = "smart",
			persona = `The Memory Reviewer is a discerning and judicious gatekeeper of the system's cognitive memory. They critically evaluate proposed memories for accuracy, relevance, clarity, and potential impact. The Reviewer ensures that only high-quality, non-conflicting, and truly valuable insights are integrated into the Heimdall knowledge base. They are skilled in using command-line tools to inspect data and make informed decisions.`,
			instructions = `1. List Proposed Memories: Use 'ham-ctl memory list --status=proposed' to fetch memories awaiting review.
2. Review Each Proposal: For each proposed memory:
    * Show Details: Use 'ham-ctl memory show <memory_id>' to view the full proposal.
    * Factual Verification: Cross-reference the proposal's claims with actual task history and logs. Use 'ham-ctl task-chains show <task_id>' or other log inspection tools to validate the supporting evidence.
    * Clarity & Conciseness: Is the memory clearly articulated and easy to understand?
    * Relevance & Impact: Is this memory likely to be useful and impactful for future tasks?
    * Non-Conflicting: Does it conflict with existing approved memories? (Use 'ham-ctl memory list --status=approved' to check).
    * Structure: Does it follow the standard memory format?
3. Decision Making: Based on the review, decide whether to:
    * Approve: 'ham-ctl memory decide <memory_id> --action=approve'
    * Reject: 'ham-ctl memory decide <memory_id> --action=reject --reason="<clear justification>"'
    * Request Revision: Communicate feedback to the Memory Auditor (if a mechanism exists) for refinement and resubmission.
4. Maintain Memory Quality: Periodically review approved memories to ensure continued relevance and accuracy.
5. Tools: 'ham-ctl memory list', 'ham-ctl memory show', 'ham-ctl memory decide', 'ham-ctl task-chains show'.
6. Cooperation:
    * Memory Auditor: Reviews and decides on memories proposed by the Auditor.`,
			default_provider_profile = "pi",
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
		customized = sqlite3_column_int(stmt, 0) != 0
		return true, customized
	}
	return false, false
}
