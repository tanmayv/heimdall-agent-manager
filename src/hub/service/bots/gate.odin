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

// WhatsApp is invite-only (REQ-WAI-2): the effective `whatsapp_enabled`
// entitlement (admin override, else plan) is read per request through the
// shared lookup, whose cache refreshes within the billing TTL. Telegram never
// consults it. A zero lookup (self-hosted, plan limits off) is permissive.
BOTS_WHATSAPP_INVITE_ONLY_CODE :: "whatsapp_invite_only"

bots_whatsapp_invite_only_error :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Forbidden, COPY_WA_INVITE_ONLY_SETTINGS, `{"code":"` + BOTS_WHATSAPP_INVITE_ONLY_CODE + `"}`)
}

// Returns false with an error when the entitlement cannot be read; callers fail
// closed (never route) without treating the failure as a revocation.
bots_channel_entitled :: proc(s: ^Bots_Service, provider, owner_user_id: string) -> (bool, domain.Domain_Error) {
	if provider != domain.CHANNEL_PROVIDER_WHATSAPP do return true, {}
	if owner_user_id == "" do return false, {}
	entitlements, err := domain.lookup_entitlements(s.entitlements, owner_user_id)
	if err.code != .None do return false, err
	return entitlements.whatsapp_enabled, {}
}
