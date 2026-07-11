package main

DEFAULT_IDLE_SHUTDOWN_MS :: 30 * 60 * 1000

Team_Role_Slot :: struct {
	role_key: string,
	agent_template_id: string,
	count: int,
	default_tier: string,
	default_provider: string,
}

Team_Chain_Scaffold_Task :: struct {
	key: string,
	title_template: string,
	role_key: string,
	reviewer_role: string,
	depends_on: []string,
	description_key: string,
}

Team_Chain_Scaffold :: struct {
	key: string,
	title_template: string,
	tasks: []Team_Chain_Scaffold_Task,
}

Team_Kind_Def :: struct {
	key: string,
	display_name: string,
	description: string,
	roles: []Team_Role_Slot,
	memory_templates: []string,
	memory_templates_inherit_from_role: string,
	scaffolds: []Team_Chain_Scaffold,
	wants_vcs: bool,
	wants_vcs_follows_project: bool,
	idle_shutdown_ms: int,
}

coding_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "coder", agent_template_id = "coder", count = 1, default_tier = "normal", default_provider = ""},
	{role_key = "reviewer", agent_template_id = "reviewer", count = 1, default_tier = "smart", default_provider = ""},
}
coding_memory_templates := [3]string{"bootstrap-guidance", "coding-conventions", "git-hygiene"}
// Reviewer participation happens via lgtm_required on the preceding work task,
// so we no longer emit a standalone review task where the reviewer is the assignee.
coding_feature_dep_implement := [1]string{"plan"}
coding_feature_dep_validate := [1]string{"implement"}
coding_feature_dep_summary := [1]string{"validate"}
coding_feature_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "plan", title_template = "Plan: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-coding-plan"},
	{key = "implement", title_template = "Implement: {chain_title}", role_key = "coder", reviewer_role = "reviewer", depends_on = coding_feature_dep_implement[:], description_key = "scaffold-coding-implement"},
	{key = "validate", title_template = "Validate: {chain_title}", role_key = "coder", reviewer_role = "reviewer", depends_on = coding_feature_dep_validate[:], description_key = "scaffold-coding-validate"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = coding_feature_dep_summary[:], description_key = "scaffold-coding-summary"},
}
coding_bugfix_dep_fix := [1]string{"reproduce"}
coding_bugfix_dep_summary := [1]string{"fix"}
coding_bugfix_tasks := [3]Team_Chain_Scaffold_Task{
	{key = "reproduce", title_template = "Reproduce: {chain_title}", role_key = "coder", reviewer_role = "reviewer", description_key = "scaffold-coding-reproduce"},
	{key = "fix", title_template = "Fix: {chain_title}", role_key = "coder", reviewer_role = "reviewer", depends_on = coding_bugfix_dep_fix[:], description_key = "scaffold-coding-fix"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = coding_bugfix_dep_summary[:], description_key = "scaffold-coding-summary"},
}
coding_refactor_dep_refactor := [1]string{"plan"}
coding_refactor_dep_validate := [1]string{"refactor"}
coding_refactor_dep_summary := [1]string{"validate"}
coding_refactor_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "plan", title_template = "Plan: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-coding-plan"},
	{key = "refactor", title_template = "Refactor: {chain_title}", role_key = "coder", reviewer_role = "reviewer", depends_on = coding_refactor_dep_refactor[:], description_key = "scaffold-coding-refactor"},
	{key = "validate", title_template = "Validate: {chain_title}", role_key = "coder", reviewer_role = "reviewer", depends_on = coding_refactor_dep_validate[:], description_key = "scaffold-coding-validate"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = coding_refactor_dep_summary[:], description_key = "scaffold-coding-summary"},
}
coding_scaffolds := [3]Team_Chain_Scaffold{
	{key = "feature", title_template = "Feature: {chain_title}", tasks = coding_feature_tasks[:]},
	{key = "bugfix", title_template = "Bugfix: {chain_title}", tasks = coding_bugfix_tasks[:]},
	{key = "refactor", title_template = "Refactor: {chain_title}", tasks = coding_refactor_tasks[:]},
}

research_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "researcher", agent_template_id = "specialist", count = 2, default_tier = "smart", default_provider = ""},
	{role_key = "reviewer", agent_template_id = "reviewer", count = 1, default_tier = "smart", default_provider = ""},
}
research_memory_templates := [3]string{"bootstrap-guidance", "research-method", "source-hygiene"}
research_report_dep_gather := [1]string{"scope"}
research_report_dep_synthesize := [1]string{"gather"}
research_report_dep_summary := [1]string{"synthesize"}
research_report_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "scope", title_template = "Scope: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-research-scope"},
	{key = "gather", title_template = "Gather: {chain_title}", role_key = "researcher", reviewer_role = "reviewer", depends_on = research_report_dep_gather[:], description_key = "scaffold-research-gather"},
	{key = "synthesize", title_template = "Synthesize: {chain_title}", role_key = "researcher", reviewer_role = "reviewer", depends_on = research_report_dep_synthesize[:], description_key = "scaffold-research-synthesize"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = research_report_dep_summary[:], description_key = "scaffold-research-summary"},
}
research_spike_dep_explore := [1]string{"question"}
research_spike_dep_conclude := [1]string{"explore"}
research_spike_dep_summary := [1]string{"conclude"}
research_spike_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "question", title_template = "Question: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-research-question"},
	{key = "explore", title_template = "Explore: {chain_title}", role_key = "researcher", reviewer_role = "reviewer", depends_on = research_spike_dep_explore[:], description_key = "scaffold-research-explore"},
	{key = "conclude", title_template = "Conclude: {chain_title}", role_key = "researcher", reviewer_role = "reviewer", depends_on = research_spike_dep_conclude[:], description_key = "scaffold-research-conclude"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = research_spike_dep_summary[:], description_key = "scaffold-research-summary"},
}
research_scaffolds := [2]Team_Chain_Scaffold{
	{key = "report", title_template = "Report: {chain_title}", tasks = research_report_tasks[:]},
	{key = "spike", title_template = "Spike: {chain_title}", tasks = research_spike_tasks[:]},
}

debugging_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "debugger", agent_template_id = "coder", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "reviewer", agent_template_id = "reviewer", count = 1, default_tier = "smart", default_provider = ""},
}
debugging_memory_templates := [3]string{"bootstrap-guidance", "debugging-playbook", "evidence-collection"}
debug_bug_dep_isolate := [1]string{"reproduce"}
debug_bug_dep_fix := [1]string{"isolate"}
debug_bug_dep_summary := [1]string{"fix"}
debug_bug_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "reproduce", title_template = "Reproduce: {chain_title}", role_key = "debugger", reviewer_role = "reviewer", description_key = "scaffold-debugging-reproduce"},
	{key = "isolate", title_template = "Isolate: {chain_title}", role_key = "debugger", reviewer_role = "reviewer", depends_on = debug_bug_dep_isolate[:], description_key = "scaffold-debugging-isolate"},
	{key = "fix", title_template = "Fix: {chain_title}", role_key = "debugger", reviewer_role = "reviewer", depends_on = debug_bug_dep_fix[:], description_key = "scaffold-debugging-fix"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = debug_bug_dep_summary[:], description_key = "scaffold-debugging-summary"},
}
debug_incident_dep_mitigate := [1]string{"triage"}
debug_incident_dep_root_cause := [1]string{"mitigate"}
debug_incident_dep_fix := [1]string{"root-cause"}
debug_incident_dep_post_mortem := [1]string{"fix"}
debug_incident_tasks := [5]Team_Chain_Scaffold_Task{
	{key = "triage", title_template = "Triage: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-debugging-triage"},
	{key = "mitigate", title_template = "Mitigate: {chain_title}", role_key = "debugger", reviewer_role = "reviewer", depends_on = debug_incident_dep_mitigate[:], description_key = "scaffold-debugging-mitigate"},
	{key = "root-cause", title_template = "Root cause: {chain_title}", role_key = "debugger", reviewer_role = "reviewer", depends_on = debug_incident_dep_root_cause[:], description_key = "scaffold-debugging-root-cause"},
	{key = "fix", title_template = "Fix: {chain_title}", role_key = "debugger", reviewer_role = "reviewer", depends_on = debug_incident_dep_fix[:], description_key = "scaffold-debugging-fix"},
	{key = "post-mortem", title_template = "Post-mortem: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = debug_incident_dep_post_mortem[:], description_key = "scaffold-debugging-post-mortem"},
}
debugging_scaffolds := [2]Team_Chain_Scaffold{
	{key = "bug", title_template = "Bug: {chain_title}", tasks = debug_bug_tasks[:]},
	{key = "incident", title_template = "Incident: {chain_title}", tasks = debug_incident_tasks[:]},
}

data_analysis_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "analyst", agent_template_id = "specialist", count = 2, default_tier = "normal", default_provider = ""},
	{role_key = "reviewer", agent_template_id = "reviewer", count = 1, default_tier = "smart", default_provider = ""},
}
data_analysis_memory_templates := [3]string{"bootstrap-guidance", "data-hygiene", "notebook-discipline"}
data_analysis_dep_explore := [1]string{"define"}
data_analysis_dep_analyze := [1]string{"explore"}
data_analysis_dep_report := [1]string{"analyze"}
data_analysis_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "define", title_template = "Define: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-data-analysis-define"},
	{key = "explore", title_template = "Explore: {chain_title}", role_key = "analyst", reviewer_role = "reviewer", depends_on = data_analysis_dep_explore[:], description_key = "scaffold-data-analysis-explore"},
	{key = "analyze", title_template = "Analyze: {chain_title}", role_key = "analyst", reviewer_role = "reviewer", depends_on = data_analysis_dep_analyze[:], description_key = "scaffold-data-analysis-analyze"},
	{key = "report", title_template = "Report: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = data_analysis_dep_report[:], description_key = "scaffold-data-analysis-report"},
}
data_analysis_scaffolds := [1]Team_Chain_Scaffold{
	{key = "analysis", title_template = "Analysis: {chain_title}", tasks = data_analysis_tasks[:]},
}

writing_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "writer", agent_template_id = "specialist", count = 1, default_tier = "normal", default_provider = ""},
	{role_key = "reviewer", agent_template_id = "reviewer", count = 1, default_tier = "smart", default_provider = ""},
}
writing_memory_templates := [2]string{"bootstrap-guidance", "writing-style"}
writing_dep_draft := [1]string{"outline"}
writing_dep_publish := [1]string{"draft"}
writing_tasks := [3]Team_Chain_Scaffold_Task{
	{key = "outline", title_template = "Outline: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", description_key = "scaffold-writing-outline"},
	{key = "draft", title_template = "Draft: {chain_title}", role_key = "writer", reviewer_role = "reviewer", depends_on = writing_dep_draft[:], description_key = "scaffold-writing-draft"},
	{key = "publish", title_template = "Publish: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = writing_dep_publish[:], description_key = "scaffold-writing-publish"},
}
writing_scaffolds := [1]Team_Chain_Scaffold{
	{key = "article", title_template = "Article: {chain_title}", tasks = writing_tasks[:]},
}

ops_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "normal", default_provider = ""},
	{role_key = "operator", agent_template_id = "coder", count = 1, default_tier = "normal", default_provider = ""},
	{role_key = "reviewer", agent_template_id = "reviewer", count = 1, default_tier = "normal", default_provider = ""},
}
ops_memory_templates := [2]string{"bootstrap-guidance", "ops-runbooks"}
ops_dep_summary := [1]string{"apply"}
ops_tasks := [2]Team_Chain_Scaffold_Task{
	{key = "apply", title_template = "Apply: {chain_title}", role_key = "operator", reviewer_role = "reviewer", description_key = "scaffold-ops-apply"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "reviewer", depends_on = ops_dep_summary[:], description_key = "scaffold-ops-summary"},
}
ops_scaffolds := [1]Team_Chain_Scaffold{
	{key = "chore", title_template = "Chore: {chain_title}", tasks = ops_tasks[:]},
}

solo_roles := [3]Team_Role_Slot{
	{role_key = "coordinator", agent_template_id = "lead", count = 1, default_tier = "smart", default_provider = ""},
	{role_key = "worker", agent_template_id = "specialist", count = 1, default_tier = "normal", default_provider = ""},
	{role_key = "user_proxy", agent_template_id = "", count = 1, default_tier = "", default_provider = ""},
}
solo_dep_work := [1]string{"plan"}
solo_dep_user_review := [1]string{"work"}
solo_dep_summary := [1]string{"user-review"}
solo_tasks := [4]Team_Chain_Scaffold_Task{
	{key = "plan", title_template = "Plan: {chain_title}", role_key = "coordinator", reviewer_role = "user_proxy", description_key = "scaffold-solo-plan"},
	{key = "work", title_template = "Work: {chain_title}", role_key = "worker", reviewer_role = "user_proxy", depends_on = solo_dep_work[:], description_key = "scaffold-solo-work"},
	{key = "user-review", title_template = "User review: {chain_title}", role_key = "user_proxy", reviewer_role = "coordinator", depends_on = solo_dep_user_review[:], description_key = "scaffold-solo-user-review"},
	{key = "summary", title_template = "Summary: {chain_title}", role_key = "coordinator", reviewer_role = "user_proxy", depends_on = solo_dep_summary[:], description_key = "scaffold-solo-summary"},
}
solo_scaffolds := [1]Team_Chain_Scaffold{
	{key = "solo", title_template = "Solo: {chain_title}", tasks = solo_tasks[:]},
}

team_kind_defs := [7]Team_Kind_Def{
	{key = "coding", display_name = "Coding", description = "The default kind for changes to code repositories.", roles = coding_roles[:], memory_templates = coding_memory_templates[:], scaffolds = coding_scaffolds[:], wants_vcs = true, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
	{key = "research", display_name = "Research", description = "Non-code investigative work: source review, market scan, spike write-ups.", roles = research_roles[:], memory_templates = research_memory_templates[:], scaffolds = research_scaffolds[:], wants_vcs = false, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
	{key = "debugging", display_name = "Debugging", description = "Diagnostic work with an expected fix at the end.", roles = debugging_roles[:], memory_templates = debugging_memory_templates[:], scaffolds = debugging_scaffolds[:], wants_vcs = true, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
	{key = "data-analysis", display_name = "Data analysis", description = "Notebooks, dataset exploration, and model evaluation.", roles = data_analysis_roles[:], memory_templates = data_analysis_memory_templates[:], scaffolds = data_analysis_scaffolds[:], wants_vcs = true, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
	{key = "writing", display_name = "Writing", description = "Docs, blog posts, and longer-form artifacts.", roles = writing_roles[:], memory_templates = writing_memory_templates[:], scaffolds = writing_scaffolds[:], wants_vcs = true, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
	{key = "ops", display_name = "Ops", description = "Repo/config maintenance, dependency bumps, and small automations.", roles = ops_roles[:], memory_templates = ops_memory_templates[:], scaffolds = ops_scaffolds[:], wants_vcs = true, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
	{key = "solo", display_name = "Solo", description = "A team of one backed by a synthetic user_proxy reviewer.", roles = solo_roles[:], memory_templates_inherit_from_role = "worker", scaffolds = solo_scaffolds[:], wants_vcs_follows_project = true, idle_shutdown_ms = DEFAULT_IDLE_SHUTDOWN_MS},
}

team_kind_get :: proc(key: string) -> ^Team_Kind_Def {
	for i in 0 ..< len(team_kind_defs) {
		if team_kind_defs[i].key == key do return &team_kind_defs[i]
	}
	return nil
}

team_kind_list :: proc() -> []Team_Kind_Def {
	return team_kind_defs[:]
}
