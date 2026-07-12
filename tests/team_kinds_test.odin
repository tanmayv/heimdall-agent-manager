package team_kinds_test

import "core:fmt"
import "core:os"
import daemon "odin_test:daemon"

expected_keys := [3]string{"coding", "research", "solo"}
legacy_keys := [4]string{"debugging", "data-analysis", "writing", "ops"}

main :: proc() {
	kinds := daemon.team_kind_list()
	check(len(kinds) == len(expected_keys), fmt.tprintf("expected %d team kinds, got %d", len(expected_keys), len(kinds)))

	for key in expected_keys {
		kind := daemon.team_kind_get(key)
		check(kind != nil, fmt.tprintf("missing kind %s", key))
		check(kind.expected_task_count == 1, fmt.tprintf("kind %s expected_task_count must be 1", key))
	}

	for key in legacy_keys {
		check(daemon.team_kind_get(key) == nil, fmt.tprintf("legacy kind %s must not resolve", key))
	}

	coding := daemon.team_kind_get("coding")
	check(coding.pace == "normal", "coding pace must be normal")
	check(coding.collaborating_agent_count == 4, "coding must report 4 collaborating agents")
	check(count_role(coding.roles, "tester") == 1, "coding must include one tester role")
	check(len(coding.scaffolds) == 5, "coding must expose feature, bugfix, refactor, chore, incident scaffolds")
	feature := scaffold_by_key(coding.scaffolds, "feature")
	check(feature != nil, "coding feature scaffold missing")
	check(feature.pace == "slow", "feature scaffold pace must be slow")
	check(feature.expected_task_count == 5, "feature scaffold must declare 5 tasks")
	check(feature.collaborating_agent_count == 4, "feature scaffold must declare 4 agents")
	check(task_role(feature.tasks, "contracts") == "coder", "feature contracts task must go to coder")
	check(task_role(feature.tasks, "test") == "tester", "feature test task must go to tester")
	check(task_dep(feature.tasks, "implement", 0) == "contracts", "feature implement must depend on contracts")
	check(task_dep(feature.tasks, "summary", 0) == "test", "feature summary must depend on test")

	bugfix := scaffold_by_key(coding.scaffolds, "bugfix")
	check(bugfix != nil, "coding bugfix scaffold missing")
	check(task_role(bugfix.tasks, "reproduce") == "tester", "bugfix reproduce task must go to tester")
	check(task_role(bugfix.tasks, "fix") == "coder", "bugfix fix task must go to coder")
	check(task_role(bugfix.tasks, "test") == "tester", "bugfix test task must go to tester")

	incident := scaffold_by_key(coding.scaffolds, "incident")
	check(incident != nil, "coding incident scaffold missing")
	check(task_role(incident.tasks, "root-cause") == "tester", "incident root-cause task must go to tester")

	research := daemon.team_kind_get("research")
	check(research.pace == "normal", "research pace must be normal")
	check(research.collaborating_agent_count == 3, "research must report 3 collaborating agents")
	check(count_role(research.roles, "researcher") == 1, "research must include one researcher role")
	check(role_template(research.roles, "researcher") == "researcher", "researcher role must use researcher template")
	check(len(research.scaffolds) == 3, "research must expose report, spike, analysis scaffolds")
	check(scaffold_by_key(research.scaffolds, "report") != nil, "research report scaffold missing")
	check(scaffold_by_key(research.scaffolds, "spike") != nil, "research spike scaffold missing")
	analysis := scaffold_by_key(research.scaffolds, "analysis")
	check(analysis != nil, "research analysis scaffold missing")
	check(task_role(analysis.tasks, "investigate") == "researcher", "research analysis investigate task must go to researcher")

	solo := daemon.team_kind_get("solo")
	check(solo.pace == "fast", "solo pace must be fast")
	check(solo.collaborating_agent_count == 3, "solo must report 3 collaborating agents")
	check(solo.memory_templates_inherit_from_role == "worker", "solo must inherit memory templates from worker role")
	check(solo.wants_vcs_follows_project, "solo must follow project vcs_kind")
}

count_role :: proc(roles: []daemon.Team_Role_Slot, key: string) -> int {
	count := 0
	for role in roles {
		if role.role_key == key do count += 1
	}
	return count
}

role_template :: proc(roles: []daemon.Team_Role_Slot, key: string) -> string {
	for role in roles {
		if role.role_key == key do return role.agent_template_id
	}
	return ""
}

scaffold_by_key :: proc(scaffolds: []daemon.Team_Chain_Scaffold, key: string) -> ^daemon.Team_Chain_Scaffold {
	for i in 0 ..< len(scaffolds) {
		if scaffolds[i].key == key do return &scaffolds[i]
	}
	return nil
}

task_role :: proc(tasks: []daemon.Team_Chain_Scaffold_Task, key: string) -> string {
	for task in tasks {
		if task.key == key do return task.role_key
	}
	return ""
}

task_dep :: proc(tasks: []daemon.Team_Chain_Scaffold_Task, key: string, index: int) -> string {
	for task in tasks {
		if task.key == key {
			if index < len(task.depends_on) do return task.depends_on[index]
			return ""
		}
	}
	return ""
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
