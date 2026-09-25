package sqlite

import "core:fmt"
import "core:os"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_taskchain_rollup_counts :: proc(t: ^testing.T) {
	db_path := fmt.tprintf("/tmp/test_taskchain_rollup_%d.db", os.get_pid())
	os.remove(db_path)
	defer os.remove(db_path)

	conn, open_ok, open_err := open(db_path)
	testing.expect(t, open_ok, "db open ok")
	testing.expect_value(t, open_err.code, domain.Error_Code.None)
	defer close(&conn)

	mig_ok, mig_err := run_migrations(&conn)
	testing.expect(t, mig_ok, "migrations ok")
	testing.expect_value(t, mig_err.code, domain.Error_Code.None)

	repo_impl := Taskchain_Repo_SQLite{conn = &conn}
	repo := new_taskchain_repository(&repo_impl, &conn)

	owner := domain.User_ID("user_rollup_test")
	other_owner := domain.User_ID("user_rollup_other")

	chain1 := domain.Task_Chain_ID("chain_rollup_1")
	chain2 := domain.Task_Chain_ID("chain_rollup_2")

	// Save chain 1
	c1 := domain.Task_Chain{
		chain_id      = chain1,
		owner_user_id = owner,
		title         = "Chain 1",
		publish_state = .Published,
		status        = .Active,
		kind          = "team_work",
		created_at    = "2026-09-25T10:00:00Z",
		updated_at    = "2026-09-25T10:00:00Z",
	}
	_, s1_ok, _ := iface.taskchain_save_chain(&repo, c1)
	testing.expect(t, s1_ok, "save chain 1 ok")

	// Tasks in chain 1:
	// Task 1: completed
	t1 := domain.Task{
		task_id            = domain.Task_ID("task_r_1"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 1",
		publish_state      = .Published,
		status             = .Completed,
		priority           = .P1,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_1"}]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t1)

	// Task 2: validated_good
	t2 := domain.Task{
		task_id            = domain.Task_ID("task_r_2"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 2",
		publish_state      = .Published,
		status             = .Validated_Good,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t2)

	// Task 3: in_validation with empty reviewer_refs_json "[]" (defaults to user validation)
	t3 := domain.Task{
		task_id            = domain.Task_ID("task_r_3"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 3",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t3)

	// Task 4: in_validation with reviewer_refs_json containing user
	t4 := domain.Task{
		task_id            = domain.Task_ID("task_r_4"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 4",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		reviewer_refs_json = `[{"type":"user"}]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t4)

	// Task 5: in_validation with agent-only reviewer (should NOT count as user_validation)
	t5 := domain.Task{
		task_id            = domain.Task_ID("task_r_5"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 5",
		publish_state      = .Published,
		status             = .In_Validation,
		priority           = .P1,
		reviewer_refs_json = `[{"type":"agent_id","agent_id":"agt_reviewer"}]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t5)

	// Task 6: in_progress
	t6 := domain.Task{
		task_id            = domain.Task_ID("task_r_6"),
		chain_id           = chain1,
		owner_user_id      = owner,
		title              = "Task 6",
		publish_state      = .Published,
		status             = .In_Progress,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t6)

	// Task 7: other owner task in chain 1 (must NOT be counted)
	t7 := domain.Task{
		task_id            = domain.Task_ID("task_r_7"),
		chain_id           = chain1,
		owner_user_id      = other_owner,
		title              = "Task 7 Other",
		publish_state      = .Published,
		status             = .Completed,
		priority           = .P1,
		reviewer_refs_json = `[]`,
		created_at         = "2026-09-25T10:00:00Z",
		updated_at         = "2026-09-25T10:00:00Z",
	}
	iface.taskchain_save_task(&repo, t7)

	// Run rollup query
	rollups, r_err := iface.taskchain_task_counts_by_chain(&repo, owner)
	testing.expect_value(t, r_err.code, domain.Error_Code.None)
	defer delete(rollups)

	testing.expect(t, string(chain1) in rollups, "chain1 present in rollups")
	r1 := rollups[string(chain1)]
	testing.expect_value(t, r1.total_count, 6)
	testing.expect_value(t, r1.completed_count, 2) // t1 (.Completed) + t2 (.Validated_Good)
	testing.expect_value(t, r1.user_validation_count, 2) // t3 (empty []) + t4 ("type":"user")

	// chain2 has no tasks -> absent from rollup
	testing.expect(t, !(string(chain2) in rollups), "chain2 absent from rollups")
}
