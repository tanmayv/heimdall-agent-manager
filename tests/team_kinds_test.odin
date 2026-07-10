package team_kinds_test

import "core:fmt"
import "core:os"
import daemon "odin_test:daemon"

expected_keys := [7]string{"coding", "research", "debugging", "data-analysis", "writing", "ops", "solo"}

main :: proc() {
	kinds := daemon.team_kind_list()
	check(len(kinds) == len(expected_keys), fmt.tprintf("expected %d team kinds, got %d", len(expected_keys), len(kinds)))

	for key in expected_keys {
		kind := daemon.team_kind_get(key)
		check(kind != nil, fmt.tprintf("missing kind %s", key))
		check(!has_tester_role(kind.roles), fmt.tprintf("kind %s must not include tester role", key))
	}

	coding := daemon.team_kind_get("coding")
	check(coding.scaffolds[0].tasks[1].depends_on[0] == "plan", "coding feature scaffold must be plan -> implement -> review -> validate -> summary")

	solo := daemon.team_kind_get("solo")
	check(solo.memory_templates_inherit_from_role == "worker", "solo must inherit memory templates from worker role")
	check(solo.wants_vcs_follows_project, "solo must follow project vcs_kind")
}

has_tester_role :: proc(roles: []daemon.Team_Role_Slot) -> bool {
	for role in roles {
		if role.role_key == "tester" do return true
	}
	return false
}

check :: proc(ok: bool, message: string) {
	if ok do return
	fmt.eprintln(message)
	os.exit(1)
}
