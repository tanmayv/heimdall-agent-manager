package actions

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Fail closed on missing ownership, repository failure, and an absent flag.
actions_gate_on :: proc(repo: ^iface.Experiment_Repository, owner_user_id, key: string) -> bool {
	if owner_user_id == "" do return false
	rows, err := iface.experiment_list_by_owner(repo, owner_user_id)
	defer {
		for row in rows {delete(row.owner_user_id); delete(row.key); delete(row.updated_at)}
		delete(rows)
	}
	return err.code == .None && domain.experiment_enabled_in(rows[:], key)
}

