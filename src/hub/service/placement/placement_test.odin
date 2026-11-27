package placement
import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import project_service "odin_test:hub/service/project"
import provider "odin_test:hub/service/provider"
import provider_service "odin_test:hub/service/provider"

Placement_Fixture :: struct {
	service:                                                  Service,
	providers:                                                provider_service.Provider_Service,
	provider_repo:                                            iface.Provider_Repository,
	bridge_repo:                                              iface.Bridge_Repository,
	agent_repo:                                               iface.Agent_Repository,
	registry:                                                 project_service.Bridge_Runtime_Registry,
	policy:                                                   []domain.Bot_Placement_Candidate,
	attempts:                                                 []domain.Bot_Delivery_Attempt,
	sticky:                                                   string,
	bridges:                                                  []domain.Bridge,
	models:                                                   []domain.Bridge_Provider_Models,
	provider_ids:                                             []string,
	disabled, inactive, absent, not_detected, inactive_model: bool,
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
	entry := domain.Provider_Catalog_Entry {
		provider = strings.clone(id),
		state    = strings.clone("deprecated" if (^Placement_Fixture)(ctx).inactive else "active"),
		models   = make([dynamic]domain.Provider_Model),
	}
	for model in ([]string{"old", "m1", "m2", "m3", "m4"}) do append(&entry.models, domain.Provider_Model{model_id = strings.clone(model), state = strings.clone("deprecated" if model == "old" || (^Placement_Fixture)(ctx).inactive_model else "active")})
	return entry, true, {}
}
placement_catalog_list :: proc(ctx: rawptr) -> ([dynamic]domain.Provider_Catalog_Entry, domain.Domain_Error) {
	out := make([dynamic]domain.Provider_Catalog_Entry)
	for id in placement_provider_ids(ctx) {entry, _, _ := placement_catalog_get(ctx, id); append(&out, entry)}
	return out, {}
}
placement_statuses :: proc(
	ctx: rawptr,
	bridge: string,
) -> (
	[dynamic]domain.Bridge_Provider_Status,
	domain.Domain_Error,
) {
	out := make([dynamic]domain.Bridge_Provider_Status)
	for id in placement_provider_ids(ctx) do append(&out, domain.Bridge_Provider_Status{provider = strings.clone(id), state = strings.clone("missing" if (^Placement_Fixture)(ctx).not_detected else "present")})
	return out, {}
}
// Production settings default to PTY when no transport override is stored.
placement_transport :: proc(ctx: rawptr, bridge, provider, profile: string) -> (string, domain.Domain_Error) {return "", {}}
placement_settings :: proc(
	ctx: rawptr,
	bridge: string,
) -> (
	[dynamic]domain.Bridge_Provider_Setting,
	domain.Domain_Error,
) {
	if !(^Placement_Fixture)(ctx).absent do return nil, {}
	out := make([dynamic]domain.Bridge_Provider_Setting)
	append(
		&out,
		domain.Bridge_Provider_Setting {
			provider = strings.clone("alpha"),
			profile_id = strings.clone("alpha"),
			enabled = false,
		},
	)
	return out, {}
}
placement_models :: proc(
	ctx: rawptr,
	bridge: string,
) -> (
	[dynamic]domain.Bridge_Provider_Models,
	domain.Domain_Error,
) {
	out := make([dynamic]domain.Bridge_Provider_Models)
	for row in (^Placement_Fixture)(ctx).models do if row.bridge_id == bridge do append(&out, placement_clone(row))
	return out, {}
}
placement_bridge_list :: proc(
	ctx: rawptr,
	owner: domain.User_ID,
) -> (
	[]domain.Bridge,
	domain.Domain_Error,
) {return placement_clone((^Placement_Fixture)(ctx).bridges), {}}
placement_bridge_get :: proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	for b in (^Placement_Fixture)(ctx).bridges do if b.bridge_id == id do return placement_clone(b), true, {}
	return {}, false, {}
}
placement_policy :: proc(
	ctx: rawptr,
	bot: string,
) -> (
	[]domain.Bot_Placement_Candidate,
	domain.Domain_Error,
) {return placement_clone((^Placement_Fixture)(ctx).policy), {}}
placement_attempts :: proc(
	ctx: rawptr,
	delivery: string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {return placement_clone((^Placement_Fixture)(ctx).attempts), {}}
placement_instance :: proc(
	ctx: rawptr,
	id: string,
) -> (
	domain.Agent_Instance,
	bool,
	domain.Domain_Error,
) {return domain.Agent_Instance{bridge_id = strings.clone((^Placement_Fixture)(ctx).sticky)}, true, {}}

placement_support :: proc(
	ctx: rawptr,
	agent, bridge: string,
) -> (
	domain.Agent_Bridge_Support,
	bool,
	domain.Domain_Error,
) {
	if !(^Placement_Fixture)(ctx).disabled do return {}, false, {}
	return domain.Agent_Bridge_Support{enabled = false}, true, {}
}
placement_fixture :: proc() -> ^Placement_Fixture {
	f := new(Placement_Fixture)
	f.provider_repo = {
		ctx                    = f,
		list                   = placement_catalog_list,
		get                    = placement_catalog_get,
		list_status            = placement_statuses,
		list_settings          = placement_settings,
		list_models            = placement_models,
		get_provider_transport = placement_transport,
	}
	f.providers.repo = &f.provider_repo
	f.bridge_repo = {
		ctx           = f,
		get_bridge    = placement_bridge_get,
		list_by_owner = placement_bridge_list,
	}
	f.agent_repo = {
		ctx         = f,
		get_support = placement_support,
	}
	f.service = {
		bridges   = &f.bridge_repo,
		agents    = &f.agent_repo,
		providers = &f.providers,
		registry  = &f.registry,
	}
	f.bridges = make([]domain.Bridge, 1, context.temp_allocator)
	f.bridges[0] = {
		bridge_id         = "b",
		owner_user_id     = "alice",
		status            = .Online,
		created_at        = "1",
		capabilities_json = `{"features":["x"]}`,
	}
	assert(project_service.bridge_runtime_registry_mark_live(&f.registry, "b", false, ""))
	return f
}
placement_fixture_destroy :: proc(f: ^Placement_Fixture) {project_service.bridge_runtime_registry_destroy(&f.registry)
	free(f)}
test_launch_error :: proc(
	s: ^provider.Provider_Service,
	b, p, m: string,
	profile: string = "",
) -> domain.Domain_Error {
	ps := Service {
		providers = s,
	}
	resolved, e := launchable(&ps, "", b, p, m, profile)
	delete(resolved.provider); delete(resolved.model)
	return e
}

test_bridge_eligible_table_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	for reason in ([]string {
			REASON_NOT_OWNER,
			REASON_REVOKED,
			REASON_ENROLLMENT_PENDING,
			REASON_PLAN_DISABLED,
			REASON_OFFLINE,
			REASON_NO_LIVE_CONNECTION,
			REASON_MISSING_FEATURE,
			"",
		}) {
		b := f.bridges[0]; req := Requirements {
			owner = "alice",
		}
		switch reason {
		case REASON_NOT_OWNER:
			req.owner = "bob"; b.revoked_at = "now"
		case REASON_REVOKED:
			b.revoked_at = "now"; b.enrollment_pending_until = "later"
		case REASON_ENROLLMENT_PENDING:
			b.enrollment_pending_until = "later"; b.status = .Offline
		case REASON_PLAN_DISABLED:
			b.plan_disabled_at = "now"; f.bridges[0].plan_disabled_at = "now"; b.status = .Offline
		case REASON_OFFLINE:
			b.status = .Offline
		case REASON_NO_LIVE_CONNECTION:
			b.bridge_id = "not-connected"
		case REASON_MISSING_FEATURE:
			req.features = {"missing"}
		}
		eligible, actual := bridge_eligible(&f.service, b, req)
		testing.expect_value(t, actual, reason)
		testing.expect_value(t, eligible, reason == "")
		f.bridges[0].plan_disabled_at = ""
	}
}
test_launchable_table_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	for tc in ([]struct {
			p, m, profile: string,
			mode:          int,
			code:          domain.Error_Code,
		} {
			{"", "m1", "", 0, .Unprocessable_Entity},
			{"alpha", "", "", 0, .Unprocessable_Entity},
			{"alpha", "m1", "", 1, .Provider_Unavailable},
			{"alpha", "m1", "", 2, .Unprocessable_Entity},
			{"alpha", "old", "", 0, .Unprocessable_Entity},
			{"alpha", "unknown", "", 0, .Unprocessable_Entity},
			{"alpha", "m1", "", 3, .Provider_Unavailable},
			{"alpha", "m1", "", 4, .Provider_Unavailable},
			{"alpha", "m1", "missing-profile", 0, .Provider_Unavailable},
			{"alpha", "m1", "", 0, .None},
		}) {
		f.disabled = tc.mode == 1; f.inactive = tc.mode == 2; f.absent = tc.mode == 3; f.not_detected = tc.mode == 4
		resolved, e := launchable(&f.service, "agent", "b", tc.p, tc.m, tc.profile)
		delete(resolved.provider); delete(resolved.model)
		testing.expect_value(t, e.code, tc.code)
	}
}
test_launchable_accepts_model_alias_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	f.models = {
		{
			bridge_id = "b",
			provider = "alpha",
			has_snapshot = true,
			models_json = `[{"model_id":"m1","resolved_model":"alias","state":"active"}]`,
		},
	}
	r, e := launchable(&f.service, "", "b", "alpha", "alias", "")
	defer {delete(r.provider); delete(r.model)}
	testing.expect_value(t, e.code, domain.Error_Code.None)
	testing.expect_value(t, r.model, "m1")
}
test_match_first_rule_decides_scenario :: proc(t: ^testing.T) {
	rows := match(
		{
			{bridge_id = ANY, provider = ANY, model = "m1", position = 0, tier = .Allowed},
			{bridge_id = ANY, provider = ANY, model = ANY, position = 2, tier = .Preferred},
		},
		{{bridge_id = "b", provider = "p", model = "m1"}},
		context.allocator,
	)
	defer delete(rows)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].rule_position, 0); testing.expect_value(t, rows[0].tier, Tier.Allowed)
}
test_match_wildcard_model_keeps_first_active_scenario :: proc(t: ^testing.T) {
	rows := match(
		{{bridge_id = ANY, provider = "p", model = ANY}},
		{
			{bridge_id = "b", provider = "p", model = "later", model_order = 2},
			{bridge_id = "b", provider = "p", model = "first", model_order = 1},
		},
		context.allocator,
	)
	defer delete(rows); testing.expect_value(t, len(rows), 1); testing.expect_value(t, rows[0].model, "first")
	profiles := match(
		{{bridge_id = ANY, provider = "p", model = ANY}},
		{
			{bridge_id = "b", provider = "p", provider_profile = "one", model = "first"},
			{bridge_id = "b", provider = "p", provider_profile = "two", model = "other"},
		},
		context.allocator,
	)
	defer delete(profiles)
	testing.expect_value(t, len(profiles), 1)
	if len(profiles) == 1 do testing.expect_value(t, profiles[0].provider_profile, "one")

}
test_match_empty_rules_allow_all_scenario :: proc(t: ^testing.T) {
	rows := match(
		nil,
		{
			{bridge_id = "b", provider = "p", model = "a"},
			{bridge_id = "b", provider = "p", model = "b", model_order = 1},
		},
		context.allocator,
	)
	defer delete(rows); testing.expect_value(t, len(rows), 2)
	for c in rows {testing.expect_value(t, c.tier, Tier.Allowed); testing.expect_value(t, c.rule_position, 0)}
}
test_match_order_scenario :: proc(t: ^testing.T) {
	for pair in ([][2]Candidate {
			{{tier = .Preferred, rule_position = 9}, {tier = .Allowed}},
			{{rule_position = 0, provider_order = 9}, {rule_position = 1}},
			{{provider_order = 0, model_order = 9}, {provider_order = 1}},
			{{model_order = 0, bridge_created_at = "9"}, {model_order = 1}},
			{{bridge_created_at = "1", bridge_id = "z"}, {bridge_created_at = "2", bridge_id = "a"}},
			{{bridge_id = "a"}, {bridge_id = "b"}},
		}) {testing.expect(t, rank_before(pair[0], pair[1])); testing.expect(t, !rank_before(pair[1], pair[0]))}
	rows := match(
		nil,
		{
			{bridge_id = "z", provider = "p", model = "b", model_order = 1},
			{bridge_id = "a", provider = "p", model = "a"},
		},
		context.allocator,
	)
	defer delete(rows); testing.expect_value(t, rows[0].model, "a")
}
test_match_drops_unmatched_and_duplicates_scenario :: proc(t: ^testing.T) {
	rows := match(
		{{bridge_id = "b", provider = "p", model = "yes"}},
		{
			{bridge_id = "b", provider = "p", model = "yes"},
			{bridge_id = "b", provider = "p", model = "yes"},
			{bridge_id = "b", provider = "p", model = "no"},
		},
		context.allocator,
	)
	defer delete(rows); testing.expect_value(t, len(rows), 1)
}
test_validate_rules_codes_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	for tc in ([]struct {
			rules: []Rule,
			max:   int,
			code:  string,
		} {
			{{{bridge_id = ANY, provider = ANY, model = ANY}}, 0, "too_many_candidates"},
			{{{bridge_id = "unknown", provider = ANY, model = ANY}}, 3, "unknown_bridge"},
			{{{bridge_id = ANY, provider = "unknown", model = ANY}}, 3, "unknown_provider"},
			{{{bridge_id = ANY, provider = ANY, model = "m"}}, 3, "model_requires_provider"},
			{
				{{bridge_id = ANY, provider = ANY, model = ANY}, {bridge_id = ANY, provider = ANY, model = ANY}},
				3,
				"duplicate_candidate",
			},
		}) {e := validate_rules(&f.service, "alice", tc.rules, tc.max); testing.expect(t, strings.contains(e.details_json, tc.code))}
}
test_select_prefer_bridge_wins_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	f.bridges = {
		{bridge_id = "b", owner_user_id = "alice", status = .Online, created_at = "1"},
		{bridge_id = "c", owner_user_id = "alice", status = .Online, created_at = "2"},
	}
	assert(project_service.bridge_runtime_registry_mark_live(&f.registry, "c", false, ""))
	c, ok, _ := select(&f.service, {owner = "alice", prefer_bridge = "c"}, nil, allocator = context.allocator)
	defer candidate_destroy(c, context.allocator)
	testing.expect(t, ok); testing.expect_value(t, c.bridge_id, "c")
}
test_select_exclude_and_only_bridge_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	c, chosen, _ := select(&f.service, {owner = "alice", only_bridge = "b"}, nil, allocator = context.allocator)
	defer candidate_destroy(c, context.allocator)
	testing.expect(t, chosen); testing.expect_value(t, c.bridge_id, "b")

	_, ok, reason := select(&f.service, {owner = "alice", only_bridge = "other"}, nil)
	testing.expect(t, !ok); testing.expect_value(t, reason, "no_candidate")
	_, ok, reason = select(&f.service, {owner = "alice", exclude = {"b"}}, nil)
	testing.expect(t, !ok); testing.expect_value(t, reason, "no_candidate")
}
test_select_no_candidate_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	_, ok, reason := select(&f.service, {owner = "nobody"}, nil)
	testing.expect(t, !ok); testing.expect_value(t, reason, "no_candidate")
}
last_pick :: proc(ctx: rawptr, rows: []Candidate, req: Requirements) -> (int, bool) {return len(rows) - 1,
		len(rows) > 0}
test_second_selector_needs_no_caller_change_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	selector_register(&f.service, {name = "last", pick = last_pick}); defer service_destroy(&f.service)
	c, ok, _ := select(&f.service, {owner = "alice"}, nil, selector = "last", allocator = context.allocator)
	defer candidate_destroy(c, context.allocator)
	testing.expect(t, ok); testing.expect_value(t, c.provider, "beta"); testing.expect_value(t, c.model, "m4")
	_, missing, reason := select(&f.service, {owner = "alice"}, nil, selector = "nope")
	testing.expect(t, !missing); testing.expect_value(t, reason, "unknown_selector")
}
test_candidates_allocator_ownership_scenario :: proc(t: ^testing.T) {
	f := placement_fixture(); defer placement_fixture_destroy(f)
	rows := candidates(&f.service, {owner = "alice"}, context.allocator)
	testing.expect_value(t, len(rows), 8)
	candidates_destroy(rows, context.allocator)
}

test_bridge_models_persistence_effective_launch_and_isolation_scenario :: proc(t: ^testing.T) {
	conn, ok, _ := sqlite.open(":memory:")
	if !testing.expect(t, ok) do return
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	defer sqlite.close(&conn)
	testing.expect(
		t,
		sqlite.exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES ('models-a','alice','',''),('models-b','bob','','');",
		),
	)
	impl: sqlite.Provider_Repo_SQLite
	repo := sqlite.new_provider_repository(&impl, &conn)
	svc := provider.new_provider_service(&repo)
	defer delete(svc.test_runs)
	for bid in ([]string{"models-a", "models-b"}) {
		_, err := iface.bridge_provider_status_upsert(
			&repo,
			{bridge_id = bid, provider = "codex", binary_path = "/bin/codex", state = "present"},
		)
		testing.expect_value(t, err.code, domain.Error_Code.None)
		_, err = iface.bridge_provider_setting_upsert(&repo, {bridge_id = bid, provider = "codex", enabled = true})
		testing.expect_value(t, err.code, domain.Error_Code.None)
	}
	allowed := []string{"codex"}
	first := provider.Model_Discovery_Item {
		provider            = "codex",
		binary_path         = "/bin/codex",
		version_text        = "v1",
		has_snapshot        = true,
		models              = []provider.Discovered_Model {
			{model_id = "new-seed-absent-id", label = "New", resolved_model = "resolved-id"},
		},
		models_source       = "codex_app_server",
		models_checked_at   = "2026-10-01T00:00:00Z",
		models_attempted_at = "2026-10-01T00:00:00Z",
		models_state        = "success",
	}
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "models-a", allowed, []provider.Model_Discovery_Item{first}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		test_launch_error(&svc, "models-a", "codex", "new-seed-absent-id").code,
		domain.Error_Code.None,
	)
	testing.expect(
		t,
		test_launch_error(&svc, "models-b", "codex", "new-seed-absent-id").code != .None,
		"another bridge/account keeps its fallback list",
	)
	catalog, _, _ := iface.provider_catalog_get(&repo, "codex")
	for m in catalog.models do testing.expect(t, m.model_id != "new-seed-absent-id", "global catalog remains unchanged")
	domain.provider_catalog_entry_destroy(catalog)

	// Both ordinary and extension detection ingestion use this path. Neither
	// can erase an independent model snapshot.
	testing.expect_value(
		t,
		provider.apply_discovery_report(&svc, "models-a", []domain.Bridge_Provider_Status{{bridge_id = "models-a", provider = "codex", state = "present", extension_state = "error"}}).code,
		domain.Error_Code.None,
	)
	failed := provider.Model_Discovery_Item {
		provider            = "codex",
		models_state        = "authentication_required",
		models_attempted_at = "2026-10-02T00:00:00Z",
	}
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "models-a", allowed, []provider.Model_Discovery_Item{failed}).code,
		domain.Error_Code.None,
	)
	views, view_err := provider.list_bridge_providers(&svc, "models-a")
	testing.expect_value(t, view_err.code, domain.Error_Code.None)
	for v in views do if v.catalog.provider == "codex" {
		testing.expect(t, v.models_has_snapshot)
		testing.expect_value(t, v.models_state, "authentication_required")
		testing.expect_value(t, v.models_checked_at, first.models_checked_at)
		testing.expect_value(t, v.models_source, "codex_app_server")
		testing.expect_value(t, len(v.catalog.models), 1)
		if len(v.catalog.models) == 1 {
			testing.expect_value(t, v.catalog.models[0].model_id, "new-seed-absent-id")
			testing.expect_value(t, v.catalog.models[0].resolved_model, "resolved-id")
		}
	}
	provider.bridge_provider_views_destroy(views)
	testing.expect_value(
		t,
		test_launch_error(&svc, "models-a", "codex", "new-seed-absent-id").code,
		domain.Error_Code.None,
	)
	// Identical completed success advances checked time, with no TTL semantics.
	first.models_checked_at = "2026-10-03T00:00:00Z"; first.models_attempted_at = first.models_checked_at
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "models-a", allowed, []provider.Model_Discovery_Item{first}).code,
		domain.Error_Code.None,
	)
	saved, _ := iface.bridge_provider_models_list(&repo, "models-a")
	testing.expect_value(t, saved[0].models_checked_at, first.models_checked_at)
	domain.bridge_provider_models_list_destroy(saved)
	// Empty success is authoritative and must never resurrect static models.
	first.models =
		nil; first.models_checked_at = "2026-10-04T00:00:00Z"; first.models_attempted_at = first.models_checked_at
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "models-a", allowed, []provider.Model_Discovery_Item{first}).code,
		domain.Error_Code.None,
	)
	testing.expect(t, test_launch_error(&svc, "models-a", "codex", "new-seed-absent-id").code != .None)
	entry, _, _ := iface.provider_catalog_get(&repo, "codex")
	testing.expect_value(t, provider.apply_effective_models(&repo, "models-a", &entry).code, domain.Error_Code.None)
	testing.expect_value(t, len(entry.models), 0)
	domain.provider_catalog_entry_destroy(entry)
	// A failed first attempt leaves a labelled static fallback.
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "models-b", allowed, []provider.Model_Discovery_Item{failed}).code,
		domain.Error_Code.None,
	)
	views, _ = provider.list_bridge_providers(&svc, "models-b")
	for v in views do if v.catalog.provider == "codex" {
		testing.expect(t, !v.models_has_snapshot && len(v.catalog.models) > 0)
		testing.expect_value(t, v.models_source, "static_fallback")
	}
	provider.bridge_provider_views_destroy(views)
	// An explicit failed refresh can recover a Bridge's persisted last-good
	// snapshot when the Hub has never received it. Keep its failure state.
	recovered := provider.Model_Discovery_Item {
		provider            = "codex",
		has_snapshot        = true,
		models              = []provider.Discovered_Model{{model_id = "bridge-last-good", label = "Recovered"}},
		models_source       = "codex_app_server",
		models_checked_at   = "2026-10-01T00:00:00Z",
		models_attempted_at = "2026-10-05T00:00:00Z",
		models_state        = "timeout",
	}
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "models-b", allowed, []provider.Model_Discovery_Item{recovered}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		test_launch_error(&svc, "models-b", "codex", "bridge-last-good").code,
		domain.Error_Code.None,
	)

}

test_profiles_model_status_settings_isolate_accounts_and_custom_models_scenario :: proc(t: ^testing.T) {

	conn, ok, _ := sqlite.open(":memory:")
	if !testing.expect(t, ok) do return
	migrated, _ := sqlite.run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	defer sqlite.close(&conn)
	testing.expect(
		t,
		sqlite.exec(
			&conn,
			"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('profile-models','owner','','');",
		),
	)
	impl: sqlite.Provider_Repo_SQLite
	repo := sqlite.new_provider_repository(&impl, &conn)
	svc := provider.new_provider_service(&repo)
	testing.expect_value(
		t,
		provider.apply_profiles_report(&svc, "profile-models", []domain.Bridge_Provider_Profile{{profile_id = "codex_one", provider = "codex", enabled = true, state = "ok"}, {profile_id = "codex_two", provider = "codex", enabled = true, state = "ok"}}).code,
		domain.Error_Code.None,
	)
	for id in ([]string{"codex_one", "codex_two"}) {
		testing.expect_value(
			t,
			provider.apply_discovery_report(&svc, "profile-models", []domain.Bridge_Provider_Status{{bridge_id = "profile-models", profile_id = id, provider = "codex", binary_path = "/private/bin", state = "present"}}).code,
			domain.Error_Code.None,
		)
	}
	first := provider.Model_Discovery_Item {
		profile_id          = "codex_one",
		provider            = "codex",
		binary_path         = "/private/bin",
		models_state        = "unsupported",
		models_attempted_at = "today",
		custom_models       = []string{"private-model-one"},
	}
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "profile-models", []string{"codex"}, []provider.Model_Discovery_Item{first}, "codex_one").code,
		domain.Error_Code.None,
	)
	err := test_launch_error(&svc, "profile-models", "codex", "private-model-one", "codex_one")
	testing.expect_value(t, err.code, domain.Error_Code.None)
	err = test_launch_error(&svc, "profile-models", "codex", "private-model-one", "codex_two")
	testing.expect(t, err.code != .None, "another account cannot borrow custom models")
	first.has_snapshot =
		true; first.models_state = "success"; first.models_source = "codex_app_server"; first.models_checked_at = "today"
	first.models = []provider.Discovered_Model {
		{model_id = "observed-one", label = "Observed"},
		{model_id = "private-model-one", label = "Custom"},
	}
	first.observed_models_json = "[{\"model_id\":\"observed-one\",\"label\":\"Observed\"}]"
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "profile-models", []string{"codex"}, []provider.Model_Discovery_Item{first}, "codex_one").code,
		domain.Error_Code.None,
	)
	first.custom_models =
		nil; first.has_snapshot = false; first.models = nil; first.observed_models_json = ""; first.models_state = "authentication_required"
	testing.expect_value(
		t,
		provider.apply_model_discovery_report(&svc, "profile-models", []string{"codex"}, []provider.Model_Discovery_Item{first}, "codex_one").code,
		domain.Error_Code.None,
	)
	err = test_launch_error(&svc, "profile-models", "codex", "observed-one", "codex_one")
	testing.expect(t, err.code == .None, "failed probe retains last good observed model")
	err = test_launch_error(&svc, "profile-models", "codex", "private-model-one", "codex_one")
	testing.expect(t, err.code != .None, "clearing custom models cannot leave a ghost in observed provenance")
	statuses, _ := repo.list_status(repo.ctx, "profile-models")
	testing.expect_value(t, len(statuses), 2)
	for s in statuses do testing.expect_value(t, s.binary_path, "")
	models, _ := repo.list_models(repo.ctx, "profile-models")
	for m in models do testing.expect_value(t, m.binary_path, "")
	_, _ = repo.upsert_setting(
		repo.ctx,
		{bridge_id = "profile-models", provider = "codex", profile_id = "codex_one", enabled = false},
	)
	err = test_launch_error(&svc, "profile-models", "codex", "observed-one", "codex_one")
	testing.expect(t, err.code != .None, "profile setting disables only that identity")
}

@(test)
test_bridge_eligible_table :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_bridge_eligible_table_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_launchable_table :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_launchable_table_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_launchable_accepts_model_alias :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_launchable_accepts_model_alias_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_match_first_rule_decides :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_match_first_rule_decides_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_match_wildcard_model_keeps_first_active :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_match_wildcard_model_keeps_first_active_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_match_empty_rules_allow_all :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_match_empty_rules_allow_all_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_match_order :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_match_order_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_match_drops_unmatched_and_duplicates :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_match_drops_unmatched_and_duplicates_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_validate_rules_codes :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_validate_rules_codes_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_select_prefer_bridge_wins :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_select_prefer_bridge_wins_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_select_exclude_and_only_bridge :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_select_exclude_and_only_bridge_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_select_no_candidate :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_select_no_candidate_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_second_selector_needs_no_caller_change :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_second_selector_needs_no_caller_change_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_candidates_allocator_ownership :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	test_candidates_allocator_ownership_scenario(t)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_bridge_models_persistence_effective_launch_and_isolation :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	context.allocator = virtual.arena_allocator(&arena)
	test_bridge_models_persistence_effective_launch_and_isolation_scenario(t)
	virtual.arena_destroy(&arena)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_profiles_model_status_settings_isolate_accounts_and_custom_models :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	arena: virtual.Arena
	assert(virtual.arena_init_growing(&arena) == nil)
	context.allocator = virtual.arena_allocator(&arena)
	test_profiles_model_status_settings_isolate_accounts_and_custom_models_scenario(t)
	virtual.arena_destroy(&arena)
	testing.expect_value(t, len(track.allocation_map), 0)
}


plan_read_error :: proc(ctx: rawptr, id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	return {}, false, domain.domain_error(.Internal_Error, "plan bridge reread failed")
}
@(test)
test_plan_reread_failure_refuses_launch :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator); defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	{
		f := placement_fixture()
		b := f.bridges[0]; b.plan_disabled_at = "stale"
		f.bridges = nil
		eligible, reason := bridge_eligible(&f.service, b, {owner = "alice"})
		testing.expect(t, !eligible)
		testing.expect_value(t, reason, REASON_PLAN_DISABLED)
		testing.expect_value(t, eligibility_error(&f.service, b, reason).code, domain.Error_Code.Not_Found)
		f.bridge_repo.get_bridge = plan_read_error
		eligible, reason = bridge_eligible(&f.service, b, {owner = "alice"})
		testing.expect(t, !eligible)
		e := eligibility_error(&f.service, b, reason)
		testing.expect_value(t, e.code, domain.Error_Code.Internal_Error)
		testing.expect_value(t, e.message, "plan bridge reread failed")
		placement_fixture_destroy(f)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}
