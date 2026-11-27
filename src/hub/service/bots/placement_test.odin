package bots

import "core:encoding/json"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"
import provider_service "odin_test:hub/service/provider"
import project_service "odin_test:hub/service/project"

Placement_Fixture :: struct {
	service: Bots_Service,
	providers: provider_service.Provider_Service,
	provider_repo: iface.Provider_Repository,
	bridge_repo: iface.Bridge_Repository,
	agent_repo: iface.Agent_Repository,
	agents: agent_service.Agent_Service,
	bot_repo: iface.Bot_Repository,
	registry: project_service.Bridge_Runtime_Registry,
	policy: []domain.Bot_Placement_Candidate,
	attempts: []domain.Bot_Delivery_Attempt,
	sticky: string,
	bridges: []domain.Bridge,
	models: []domain.Bridge_Provider_Models,
	provider_ids: []string,
 disabled_support,inactive_provider:bool,
}
placement_clone :: proc(value: $T) -> T {
	data, _ := json.marshal(value, allocator = context.temp_allocator)
	result: T
	assert(json.unmarshal(data, &result) == nil)
	return result
}
placement_provider_ids :: proc(ctx: rawptr) -> []string {
	f := (^Placement_Fixture)(ctx)
	if len(f.provider_ids) > 0 do return f.provider_ids
	ids := make([]string, 2, context.temp_allocator)
	ids[0], ids[1] = "alpha", "beta"
	return ids
}
placement_catalog_get :: proc(ctx: rawptr, id: string) -> (domain.Provider_Catalog_Entry, bool, domain.Domain_Error) {
	known := false
	for provider in placement_provider_ids(ctx) do if provider == id do known = true
	if !known do return {}, false, {}
	entry := domain.Provider_Catalog_Entry{provider = strings.clone(id), state = strings.clone("deprecated" if (^Placement_Fixture)(ctx).inactive_provider else "active"), models = make([dynamic]domain.Provider_Model)}
	for model in ([]string{"old", "m1", "m2", "m3", "m4"}) do append(&entry.models, domain.Provider_Model{model_id = strings.clone(model), state = strings.clone("deprecated" if model == "old" else "active")})
	return entry, true, {}
}
placement_catalog_list :: proc(ctx: rawptr) -> ([dynamic]domain.Provider_Catalog_Entry, domain.Domain_Error) {
	out := make([dynamic]domain.Provider_Catalog_Entry)
	for id in placement_provider_ids(ctx) {entry, _, _ := placement_catalog_get(ctx, id); append(&out, entry)}
	return out, {}
}
placement_statuses :: proc(ctx: rawptr, bridge: string) -> ([dynamic]domain.Bridge_Provider_Status, domain.Domain_Error) {
	out := make([dynamic]domain.Bridge_Provider_Status)
	for id in placement_provider_ids(ctx) do append(&out, domain.Bridge_Provider_Status{provider = strings.clone(id), state = strings.clone("present")})
	return out, {}
}
// Production settings default to PTY when no transport override is stored.
placement_transport :: proc(ctx: rawptr, bridge, provider, profile: string) -> (string, domain.Domain_Error) {return "", {}}
placement_settings :: proc(ctx: rawptr, bridge: string) -> ([dynamic]domain.Bridge_Provider_Setting, domain.Domain_Error) {return nil, {}}
placement_models :: proc(ctx: rawptr, bridge: string) -> ([dynamic]domain.Bridge_Provider_Models, domain.Domain_Error) {
	out := make([dynamic]domain.Bridge_Provider_Models)
	for row in (^Placement_Fixture)(ctx).models do if row.bridge_id == bridge do append(&out, placement_clone(row))
	return out, {}
}
placement_bridge_list :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Bridge, domain.Domain_Error) {return placement_clone((^Placement_Fixture)(ctx).bridges), {}}
placement_bridge_get :: proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	for b in (^Placement_Fixture)(ctx).bridges do if b.bridge_id == id do return placement_clone(b), true, {}
	return {}, false, {}
}
placement_policy :: proc(ctx: rawptr, bot: string) -> ([]domain.Bot_Placement_Candidate, domain.Domain_Error) {return placement_clone((^Placement_Fixture)(ctx).policy), {}}
placement_attempts :: proc(ctx: rawptr, delivery: string) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error) {return placement_clone((^Placement_Fixture)(ctx).attempts), {}}
placement_instance :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {return domain.Agent_Instance{bridge_id = strings.clone((^Placement_Fixture)(ctx).sticky)}, true, {}}
placement_fixture :: proc() -> ^Placement_Fixture {
	f := new(Placement_Fixture)
	f.provider_repo = {ctx = f, list = placement_catalog_list, get = placement_catalog_get, list_status = placement_statuses, list_settings = placement_settings, list_models = placement_models, get_provider_transport = placement_transport}
	f.providers.repo = &f.provider_repo
	f.bridge_repo = {ctx = f, get_bridge = placement_bridge_get, list_by_owner = placement_bridge_list}
	f.agent_repo = {ctx = f, get_instance = placement_instance,get_support=placement_test_support}
	f.agents = {agents = &f.agent_repo, bridges = &f.bridge_repo}
	f.bot_repo = {ctx = f, placement_list = placement_policy, attempt_list_for_delivery = placement_attempts}
	f.bridges=make([]domain.Bridge,1,context.temp_allocator)
 f.bridges[0]={bridge_id="b",owner_user_id="alice",status=.Online,capabilities_json=`{"features":["bot_deliver_v1","instance_reconfiguration_v1"]}`}
 assert(project_service.bridge_runtime_registry_mark_live(&f.registry,"b",false,""))
	f.service = {providers = &f.providers, bridges = &f.bridge_repo, agents = &f.agents, repo = &f.bot_repo, registry = &f.registry, timers = default_bot_timer_config()}
	return f
}
placement_fixture_destroy :: proc(f: ^Placement_Fixture) {project_service.bridge_runtime_registry_destroy(&f.registry); free(f)}

@(test)
test_placement_validation_errors :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	f.bridges = {{bridge_id = "foreign", owner_user_id = "bob"}, {bridge_id = "mine", owner_user_id = "alice", status = .Offline}}
	too_many := make([]domain.Bot_Placement_Candidate, domain.BOT_MAX_PLACEMENT_CANDIDATES+1); defer delete(too_many)
	for tc in ([]struct {rows: []domain.Bot_Placement_Candidate, code: string}{
		{too_many, "too_many_candidates"},
		{{{bridge_id = "foreign", provider = "*", model = "*"}}, "unknown_bridge"},
		{{{bridge_id = "*", provider = "absent", model = "*"}}, "unknown_provider"},
		{{{bridge_id = "*", provider = "*", model = "m1"}}, "model_requires_provider"},
		{{{bridge_id = "*", provider = "alpha", model = "*"}, {bridge_id = "*", provider = "alpha", model = "*"}}, "duplicate_candidate"},
	}) {
		err := bots_validate_placement(&f.service, "alice", tc.rows)
		testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
		testing.expect(t, strings.contains(err.details_json, tc.code))
	}
	testing.expect_value(t, bots_validate_placement(&f.service, "alice", {{bridge_id = "mine", provider = "alpha", model = "*"}}).code, domain.Error_Code.None)
}
@(test)
test_expand_candidates_empty_policy_allows_all :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	f.service.timers.bot_max_local_candidates = 16
	rows := bots_expand_candidates(&f.service, {owner_user_id="alice"}, nil, "b"); defer bots_candidates_destroy(rows)
	testing.expect_value(t, len(rows), 8)
	if len(rows) == 8 {testing.expect_value(t, rows[0].provider, "alpha"); testing.expect_value(t, rows[4].provider, "beta"); testing.expect_value(t, rows[0].tier, "allowed"); testing.expect_value(t, rows[0].provider_profile, "alpha"); testing.expect_value(t, rows[3].model, "m4")}
}
@(test)
test_expand_candidates_ranks_preferred_first :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	policy := []domain.Bot_Placement_Candidate{{bridge_id = "*", provider = "alpha", model = "m2", tier = .Allowed}, {position = 1, bridge_id = "*", provider = "beta", model = "m1", tier = .Preferred}, {position = 2, bridge_id = "*", provider = "*", model = "*", tier = .Preferred}}
	rows := bots_expand_candidates(&f.service, {owner_user_id="alice"}, policy, "b"); defer bots_candidates_destroy(rows)
	testing.expect_value(t, len(rows), 3)
	if len(rows) == 3 {testing.expect_value(t, rows[0].provider, "beta"); testing.expect_value(t, rows[1].provider, "alpha"); testing.expect_value(t, rows[2].model, "m2"); testing.expect_value(t, rows[2].tier, "allowed")}
}
@(test)
test_expand_candidates_star_model_takes_first_active :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	rows := bots_expand_candidates(&f.service, {owner_user_id="alice"}, {{bridge_id = "*", provider = "alpha", model = "*"}}, "b"); defer bots_candidates_destroy(rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 do testing.expect_value(t, rows[0].model, "m1")
}
@(test)
test_expand_candidates_truncates_to_three :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	policy := []domain.Bot_Placement_Candidate{{bridge_id = "*", provider = "alpha", model = "m1"}, {position = 1, bridge_id = "*", provider = "alpha", model = "m2"}, {position = 2, bridge_id = "*", provider = "alpha", model = "m3"}, {position = 3, bridge_id = "*", provider = "alpha", model = "m4"}}
	rows := bots_expand_candidates(&f.service, {owner_user_id="alice"}, policy, "b"); defer bots_candidates_destroy(rows)
	testing.expect_value(t, len(rows), 3)
	if len(rows) == 3 do testing.expect_value(t, rows[2].model, "m3")
}
placement_select_bridges :: proc(f: ^Placement_Fixture) {
	f.bridges = make([]domain.Bridge, 2, context.temp_allocator)
	f.bridges[0] = {bridge_id = "b1", owner_user_id = "alice", status = .Online, capabilities_json = `{"features":["bot_deliver_v1","instance_reconfiguration_v1"]}`, created_at = "1"}
	f.bridges[1] = {bridge_id = "b2", owner_user_id = "alice", status = .Online, capabilities_json = `{"features":["bot_deliver_v1","instance_reconfiguration_v1"]}`, created_at = "2"}
	for b in f.bridges do assert(project_service.bridge_runtime_registry_mark_live(&f.registry, b.bridge_id, false, ""))
}
@(test)
test_select_bridge_sticky_first :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	placement_select_bridges(f)
	f.sticky = "b2"
	selected, found := bots_select_bridge(&f.service, {owner_user_id = "alice", agent_instance_id = "i"}, {}, 1); defer delete(selected)
	testing.expect(t, found); testing.expect_value(t, selected, "b2")
	f.sticky = ""
	oldest, _ := bots_select_bridge(&f.service, {owner_user_id = "alice"}, {}, 1); defer delete(oldest)
	testing.expect_value(t, oldest, "b1")
}
@(test)
test_select_bridge_skips_tried_and_unsupported :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	placement_select_bridges(f)
	f.attempts = {{bridge_id = "b1", round = 1}}
	selected, found := bots_select_bridge(&f.service, {owner_user_id = "alice"}, {}, 1); defer delete(selected)
	testing.expect(t, found); testing.expect_value(t, selected, "b2")
	f.bridges[1].capabilities_json = `{"features":["bot_deliver_v1"]}`
	none, none_found := bots_select_bridge(&f.service, {owner_user_id = "alice"}, {}, 1); defer delete(none)
	testing.expect(t, !none_found)
	f.bridges[1].capabilities_json = `{"features":["bot_deliver_v1","instance_reconfiguration_v1"]}`
	f.bridges[1].plan_disabled_at = "now"
	_, disabled := bots_select_bridge(&f.service, {owner_user_id = "alice"}, {}, 1)
	testing.expect(t, !disabled)
}

// Snapshot aliases remain launchable wire IDs even when policy names the resolved model.
@(test)
test_placement_snapshot_alias_matches_resolved_model :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	f.provider_ids = {"claude"}
	placement_select_bridges(f)
	f.models = {{bridge_id = "b2", provider = "claude", has_snapshot = true,
	models_json = `[{"model_id":"opus","resolved_model":"claude-opus-5-5"},{"model_id":"sonnet","resolved_model":"other"}]`}}
	f.policy = {{bridge_id = "*", provider = "claude", model = "claude-opus-5-5", tier = .Preferred}}
	rows := bots_expand_candidates(&f.service, {owner_user_id="alice"}, f.policy, "b2"); defer bots_candidates_destroy(rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {testing.expect_value(t, rows[0].model, "opus"); testing.expect_value(t, rows[0].tier, "preferred")}
	selected, found := bots_select_bridge(&f.service, {owner_user_id = "alice"}, {}, 1); defer delete(selected)
	testing.expect(t, found); testing.expect_value(t, selected, "b2")
	// Catalog fallback still matches literal IDs and excludes unrelated models.
	fallback := bots_expand_candidates(&f.service, {owner_user_id="alice"}, f.policy, "b1"); defer bots_candidates_destroy(fallback)
	testing.expect_value(t, len(fallback), 0)
	direct := bots_expand_candidates(&f.service, {owner_user_id="alice"}, {{bridge_id = "*", provider = "claude", model = "opus"}}, "b2"); defer bots_candidates_destroy(direct)
	testing.expect_value(t, len(direct), 1)
	// Ranking must retain the resolved-name policy position after expansion.
	f.policy = {{bridge_id = "*", provider = "claude", model = "m1", tier = .Allowed},
	{bridge_id = "*", provider = "claude", model = "claude-opus-5-5", tier = .Preferred, position = 1}}
	preferred, preferred_found := bots_select_bridge(&f.service, {owner_user_id = "alice"}, {}, 1); defer delete(preferred)
	testing.expect(t, preferred_found); testing.expect_value(t, preferred, "b2")
}


placement_test_support :: proc(ctx:rawptr,a,b:string)->(domain.Agent_Bridge_Support,bool,domain.Domain_Error) {
 return {},(^Placement_Fixture)(ctx).disabled_support,{}
}
@(test)
test_bot_skips_inactive_catalog_provider :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=placement_fixture();defer placement_fixture_destroy(f)
 placement_select_bridges(f)
 positive,positive_ok:=bots_select_bridge(&f.service,{owner_user_id="alice"}, {},1)
 defer delete(positive)
 testing.expect(t,positive_ok)
 f.inactive_provider=true
 _,ok:=bots_select_bridge(&f.service,{owner_user_id="alice"}, {},1)
 testing.expect(t,!ok)
}
@(test)
test_bot_skips_bridge_with_agent_disabled :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=placement_fixture();defer placement_fixture_destroy(f)
 placement_select_bridges(f)
 positive,positive_ok:=bots_select_bridge(&f.service,{owner_user_id="alice",agent_id="agent"}, {},1)
 defer delete(positive)
 testing.expect(t,positive_ok)
 f.disabled_support=true
 _,ok:=bots_select_bridge(&f.service,{owner_user_id="alice",agent_id="agent"}, {},1)
 testing.expect(t,!ok)
}
