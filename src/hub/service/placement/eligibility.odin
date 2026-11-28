package placement

import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import provider_service "odin_test:hub/service/provider"
import jsonx "odin_test:lib/jsonx"

REASON_NOT_OWNER :: "not_owner"
REASON_REVOKED :: "revoked"
REASON_ENROLLMENT_PENDING :: "enrollment_pending"
REASON_PLAN_DISABLED :: "plan_disabled"
REASON_OFFLINE :: "offline"
REASON_NO_LIVE_CONNECTION :: "no_live_connection"
REASON_MISSING_FEATURE :: "missing_feature"

bridge_has_feature :: proc(b: domain.Bridge, name: string) -> bool {
	features := jsonx.extract_string_array(b.capabilities_json, "features")
	defer {for f in features do delete(f); delete(features)}
	for f in features do if f == name do return true
	return false
}
// Launch eligibility only. Never use a refusal to infer an existing runtime
// has stopped; stop/fencing paths consult connectivity separately. Plan checks
// reread the durable flag and consult billing only to describe a suspension.
bridge_eligible :: proc(s: ^Service, b: domain.Bridge, req: Requirements) -> (bool, string) {
	if string(b.owner_user_id) != req.owner do return false, REASON_NOT_OWNER
	if b.revoked_at != "" || b.status == .Revoked do return false, REASON_REVOKED
	if b.enrollment_pending_until != "" do return false, REASON_ENROLLMENT_PENDING
	disabled := b.plan_disabled_at != ""
	if s.entitlements.lookup != nil || disabled {
		current, found, read_err := iface.bridge_get_bridge(s.bridges, b.bridge_id)
		defer domain.bridge_destroy(&current)
		if !found || read_err.code != .None do return false, REASON_PLAN_DISABLED
		disabled = current.plan_disabled_at != ""
	}
	if disabled do return false, REASON_PLAN_DISABLED
	if b.status != .Online do return false, REASON_OFFLINE
	if s.registry == nil || !project.bridge_runtime_registry_has_live(s.registry, b.bridge_id) do return false, REASON_NO_LIVE_CONNECTION
	for feature in req.features do if !bridge_has_feature(b, feature) do return false, REASON_MISSING_FEATURE
	return true, ""
}
eligibility_error :: proc(s: ^Service, b: domain.Bridge, reason: string) -> domain.Domain_Error {
	if reason == "" do return {}
	if reason == REASON_PLAN_DISABLED {
		current, found, read_err := iface.bridge_get_bridge(s.bridges, b.bridge_id)
		defer domain.bridge_destroy(&current)
		if read_err.code != .None do return read_err
		if !found do return domain.domain_error(.Not_Found, "bridge not found")

		entitlements, e := domain.lookup_entitlements(s.entitlements, string(b.owner_user_id))
		if e.code != .None do return e
		count, ce := iface.bridge_count_active_by_owner(s.bridges, b.owner_user_id)
		if ce.code != .None do return ce
		e = domain.entitlement_limit_error(
			s.entitlements,
			string(b.owner_user_id),
			"max_bridges",
			entitlements.max_bridges,
			count,
		)
		e.cause = reason
		return e
	}
	code := domain.Error_Code.Conflict
	if reason == REASON_NOT_OWNER do code = .Not_Found
	if reason == REASON_OFFLINE || reason == REASON_NO_LIVE_CONNECTION do code = .Bridge_Offline
	e := domain.domain_error(code, reason)
	e.details_json = detail_error(reason).details_json
	e.cause = reason
	return e
}
bridge_status_online :: proc(bridges: ^iface.Bridge_Repository, bridge_id: string) -> bool {
	if bridges == nil || bridge_id == "" do return false
	b, found, e := iface.bridge_get_bridge(bridges, bridge_id)
	defer domain.bridge_destroy(&b)
	return found && e.code == .None && b.status == .Online
}
// On success both strings in the result are caller-owned (context.allocator).
// A missing per-agent support override leaves a bridge eligible. Both
// canonical and legacy policy roles must honor explicit disablement.
agent_bridge_support_check :: proc(s: ^Service, agent_id, bridge_id: string) -> domain.Domain_Error {
	if agent_id == "" do return {}
	support, found, err := iface.agent_get_support(s.agents, agent_id, bridge_id)
	defer support_destroy(support)
	if err.code != .None && err.code != .Not_Found do return err
	if found && !support.enabled do return domain.domain_error(.Provider_Unavailable, "agent is disabled on bridge")
	return {}
}

launchable :: proc(
	s: ^Service,
	agent_id, bridge_id, provider, model, profile: string,
) -> (
	domain.Resolved_Provider_Model,
	domain.Domain_Error,
) {
	if strings.trim_space(provider) == "" || strings.trim_space(model) == "" do return {}, domain.domain_error(.Unprocessable_Entity, "provider and model are required")
	if s == nil || s.providers == nil || s.providers.repo == nil do return {}, domain.domain_error(.Internal_Error, "provider repository is not configured")
	if e := agent_bridge_support_check(s, agent_id, bridge_id); e.code != .None do return {}, e
	if e := provider_service.validate_profile(s.providers.repo, bridge_id, provider, profile); e.code != .None do return {}, e
	entry, found, entry_err := iface.provider_catalog_get(s.providers.repo, provider)
	if entry_err.code != .None do return {}, entry_err
	defer domain.provider_catalog_entry_destroy(entry)
	if !found || entry.state != "active" do return {}, domain.domain_error(.Unprocessable_Entity, "provider is unknown or deprecated")
	if err := provider_service.apply_effective_models(s.providers.repo, bridge_id, &entry, profile); err.code != .None do return {}, err
	model_ok := false
	resolved_model := model
	for candidate in entry.models {if (candidate.model_id == model || (candidate.resolved_model != "" && candidate.resolved_model == model)) && candidate.state == "active" {model_ok = true; resolved_model = candidate.model_id; break}}
	if !model_ok do return {}, domain.domain_error(.Unprocessable_Entity, "model is unknown or deprecated for provider")
	// Single source of truth with the provider list/profile views (profile enabled AND bridge setting, default-on when present).
	view_service := provider_service.Provider_Service {
		repo = s.providers.repo,
	}
	views, views_err := provider_service.list_bridge_providers(&view_service, bridge_id)
	if views_err.code != .None do return {}, views_err
	defer provider_service.bridge_provider_views_destroy(views)
	launchable := false
	for view in views {if view.catalog.provider == provider &&
		   view.profile_id == domain.profile_effective_id(provider, profile) &&
		   view.enabled &&
		   view.detection_state == "present" {launchable = true; break}}
	if !launchable do return {}, domain.domain_error(.Provider_Unavailable, "provider is not enabled and present on bridge")
	return domain.Resolved_Provider_Model {
		provider = strings.clone(provider),
		model = strings.clone(resolved_model),
	}, domain.Domain_Error{}
}

support_destroy :: proc(s: domain.Agent_Bridge_Support) {
	delete(
		s.agent_id,
	); delete(s.bridge_id); delete(string(s.owner_user_id)); delete(s.kind); delete(s.created_at); delete(s.updated_at)
}
