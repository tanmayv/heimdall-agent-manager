package bots

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// bots_gate_error returns {} when the bots experiment is on for owner_user_id,
// otherwise the refusal. Same semantics as experiment_gate_error
// (experiment_rest_handlers.odin:158): empty owner → refusal; repository error →
// .Internal_Error (fail closed); only this owner's rows are read.
bots_gate_error :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> domain.Domain_Error {
	if owner_user_id == "" do return domain.experimental_feature_disabled_error(domain.BOTS_EXPERIMENT_KEY)
	exps, err := iface.experiment_list_by_owner(repo, owner_user_id)
	defer {
		for exp in exps {
			delete(exp.owner_user_id)
			delete(exp.key)
			delete(exp.updated_at)
		}
		delete(exps)
	}
	if err.code != .None do return domain.domain_error(.Internal_Error, "could not read experiment settings")
	if domain.experiment_enabled_in(exps[:], domain.BOTS_EXPERIMENT_KEY) do return domain.Domain_Error{}
	return domain.experimental_feature_disabled_error(domain.BOTS_EXPERIMENT_KEY)
}

// bots_gate_on is bots_gate_error == {} as a bool, for loops that skip an owner.
bots_gate_on :: proc(repo: ^iface.Experiment_Repository, owner_user_id: string) -> bool {
	return bots_gate_error(repo, owner_user_id).code == .None
}
