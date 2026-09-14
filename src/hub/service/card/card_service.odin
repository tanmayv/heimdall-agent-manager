package card

import "core:encoding/json"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"

is_valid_json_array :: proc(s: string) -> bool {
	trimmed := strings.trim_space(s)
	if trimmed == "" do return false
	val, err := json.parse_string(trimmed)
	if err != .None do return false
	defer json.destroy_value(val)
	_, is_arr := val.(json.Array)
	return is_arr
}

is_valid_json_object :: proc(s: string) -> bool {
	trimmed := strings.trim_space(s)
	if trimmed == "" do return false
	val, err := json.parse_string(trimmed)
	if err != .None do return false
	defer json.destroy_value(val)
	_, is_obj := val.(json.Object)
	return is_obj
}

Card_Input :: struct {
	project_id:       domain.Project_ID,
	title:            string,
	rationale:        string,
	scope:            string,
	provider:         string,
	confidence:       f32,
	source_refs_json: string,
	status:           string,
	operations_json:  string,
	guard_json:       string,
	snooze_until:     string,
	ttl_at:           string,
}

Card_Update_Input :: struct {
	title:            string,
	has_title:        bool,
	rationale:        string,
	has_rationale:    bool,
	scope:            string,
	has_scope:        bool,
	provider:         string,
	has_provider:     bool,
	confidence:       f32,
	has_confidence:   bool,
	source_refs_json: string,
	has_source_refs:  bool,
	status:           string,
	has_status:       bool,
	operations_json:  string,
	has_operations:   bool,
	guard_json:       string,
	has_guard:        bool,
	snooze_until:     string,
	has_snooze_until: bool,
	ttl_at:           string,
	has_ttl_at:       bool,
}

Card_Filter :: struct {
	status:     string,
	scope:      string,
	provider:   string,
	project_id: domain.Project_ID,
}

Card_Service :: struct {
	cards:    ^iface.Card_Repository,
	projects: ^iface.Project_Repository,
	clock:    ^platform.Clock,
	ids:      ^platform.ID_Generator,
}

new_card_service :: proc(cards: ^iface.Card_Repository, projects: ^iface.Project_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Card_Service {
	return Card_Service{
		cards    = cards,
		projects = projects,
		clock    = clock,
		ids      = ids,
	}
}

create_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, input: Card_Input) -> (domain.Card, bool, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return domain.Card{}, false, err

	title := strings.trim_space(input.title)
	if title == "" {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "card title is required")
	}

	scope := input.scope
	if scope == "" do scope = domain.CARD_SCOPE_PROJECT

	status := input.status
	if status == "" do status = domain.CARD_STATUS_PENDING

	confidence := input.confidence
	if confidence <= 0.0 do confidence = 1.0

	source_refs := input.source_refs_json
	if source_refs == "" {
		source_refs = "[]"
	} else if !is_valid_json_array(source_refs) {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "source_refs must be a valid JSON array")
	}

	ops := input.operations_json
	if ops == "" {
		ops = "[]"
	} else if !is_valid_json_array(ops) {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "operations must be a valid JSON array")
	}

	guard := input.guard_json
	if guard == "" {
		guard = "{}"
	} else if !is_valid_json_object(guard) {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "guard must be a valid JSON object")
	}

	now := platform.clock_now(s.clock)
	card_id := domain.Card_ID(platform.generate_id(s.ids, "crd_"))

	card := domain.Card{
		card_id          = card_id,
		owner_user_id    = owner,
		project_id       = input.project_id,
		title            = title,
		rationale        = input.rationale,
		scope            = scope,
		provider         = input.provider,
		confidence       = confidence,
		source_refs_json = source_refs,
		status           = status,
		operations_json  = ops,
		guard_json       = guard,
		snooze_until     = input.snooze_until,
		ttl_at           = input.ttl_at,
		created_at       = now,
		updated_at       = now,
	}

	return iface.card_create(s.cards, card)
}

get_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	c, ok, err := iface.card_get(s.cards, id)
	if !ok do return domain.Card{}, false, err

	if ok2, e := ownership.require_owner(auth, c.owner_user_id); !ok2 {
		return domain.Card{}, false, e
	}
	return c, true, domain.Domain_Error{}
}

list_cards :: proc(s: ^Card_Service, auth: contracts.Auth_Context, filter: Card_Filter = {}, limit: int = 50) -> ([]domain.Card, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	all, list_err := iface.card_list(s.cards, owner)
	if list_err.code != .None do return nil, list_err

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	filtered := make([dynamic]domain.Card, 0, len(all))
	defer delete(filtered)

	for c in all {
		if filter.status != "" && c.status != filter.status do continue
		if filter.scope != "" && c.scope != filter.scope do continue
		if filter.provider != "" && c.provider != filter.provider do continue
		if filter.project_id != "" && c.project_id != filter.project_id do continue
		append(&filtered, c)
	}

	count := len(filtered)
	if count > eff_limit do count = eff_limit

	out := make([]domain.Card, count)
	copy(out, filtered[:count])
	return out, domain.Domain_Error{}
}

list_cards_by_project :: proc(s: ^Card_Service, auth: contracts.Auth_Context, project_id: domain.Project_ID) -> ([]domain.Card, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	all, list_err := iface.card_list_by_project(s.cards, project_id)
	if list_err.code != .None do return nil, list_err

	filtered := make([dynamic]domain.Card, 0, len(all))
	defer delete(filtered)
	for c in all {
		if c.owner_user_id == owner {
			append(&filtered, c)
		}
	}
	out := make([]domain.Card, len(filtered))
	copy(out, filtered[:])
	return out, domain.Domain_Error{}
}

update_card_status :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, status: string) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	now := platform.clock_now(s.clock)
	up_ok, up_err := iface.card_update_status(s.cards, id, status, now)
	if !up_ok do return domain.Card{}, false, up_err

	card.status = status
	card.updated_at = now
	return card, true, domain.Domain_Error{}
}

update_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, input: Card_Update_Input) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	if input.has_title {
		t := strings.trim_space(input.title)
		if t == "" do return domain.Card{}, false, domain.domain_error(.Validation_Failed, "card title cannot be empty")
		card.title = t
	}
	if input.has_rationale do card.rationale = input.rationale
	if input.has_scope do card.scope = input.scope
	if input.has_provider do card.provider = input.provider
	if input.has_confidence do card.confidence = input.confidence
	if input.has_source_refs {
		if !is_valid_json_array(input.source_refs_json) {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "source_refs must be a valid JSON array")
		}
		card.source_refs_json = input.source_refs_json
	}
	if input.has_status do card.status = input.status
	if input.has_operations {
		if !is_valid_json_array(input.operations_json) {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "operations must be a valid JSON array")
		}
		card.operations_json = input.operations_json
	}
	if input.has_guard {
		if !is_valid_json_object(input.guard_json) {
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "guard must be a valid JSON object")
		}
		card.guard_json = input.guard_json
	}
	if input.has_snooze_until do card.snooze_until = input.snooze_until
	if input.has_ttl_at do card.ttl_at = input.ttl_at

	now := platform.clock_now(s.clock)
	card.updated_at = now
	return iface.card_update(s.cards, card)
}

discard_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	return update_card_status(s, auth, id, domain.CARD_STATUS_DISCARDED)
}

reject_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	return update_card_status(s, auth, id, domain.CARD_STATUS_REJECTED)
}

accept_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	// Guardrail for T2: do not mutate status. Accept executor lands in T3.
	_, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	return domain.Card{}, false, domain.domain_error(.Not_Implemented, "card executor is not yet available; card operations cannot be executed in this version")
}

snooze_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID, snooze_until: string) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	now := platform.clock_now(s.clock)
	card.status = domain.CARD_STATUS_SNOOZED
	card.snooze_until = snooze_until
	card.updated_at = now
	return iface.card_update(s.cards, card)
}

delete_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return false, err

	_ = card
	return iface.card_delete(s.cards, id)
}
