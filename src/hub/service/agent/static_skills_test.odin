package agent

import "core:strings"
import "core:testing"

@(test)
test_static_skills_ham_ctl_reference_content :: proc(t: ^testing.T) {
	found := false
	for skill in STATIC_SKILLS {
		if skill.slug == "ham-ctl-reference" {
			found = true
			testing.expect(t, strings.contains(skill.content, "task-chain create --title"), "ham-ctl-reference must document task-chain create")
			testing.expect(t, strings.contains(skill.content, "--coordinator"), "ham-ctl-reference must document coordinator flag")
			testing.expect(t, strings.contains(skill.content, "task-chain subscribe"), "ham-ctl-reference must document task-chain subscribe")
			testing.expect(t, strings.contains(skill.content, "task-chain unsubscribe"), "ham-ctl-reference must document task-chain unsubscribe")
			testing.expect(t, strings.contains(skill.content, "task subscribe"), "ham-ctl-reference must document task subscribe")
			testing.expect(t, strings.contains(skill.content, "task unsubscribe"), "ham-ctl-reference must document task unsubscribe")
			testing.expect(t, strings.contains(skill.content, "Pub/Sub subscription mechanism"), "ham-ctl-reference must document Pub/Sub subscription mechanism")
			testing.expect(t, strings.contains(skill.content, "notify_task_nudge"), "ham-ctl-reference must document notify_task_nudge notice delivery")
		}
	}
	testing.expect(t, found, "STATIC_SKILLS must contain ham-ctl-reference")
}
