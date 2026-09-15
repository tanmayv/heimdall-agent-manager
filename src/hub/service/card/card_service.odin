package card

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import ownership "odin_test:hub/service/ownership"
import taskchain_service "odin_test:hub/service/taskchain"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"

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

json_obj_string :: proc(obj: json.Object, key: string) -> string {
	v, ok := obj[key]
	if !ok do return ""
	s, is_str := v.(json.String)
	if is_str do return string(s)
	return ""
}

op_arg_string :: proc(obj: json.Object, key: string) -> string {
	if args_val, has_args := obj["args"]; has_args {
		if args_obj, is_args_obj := args_val.(json.Object); is_args_obj {
			if v, ok := args_obj[key]; ok {
				if s, is_s := v.(json.String); is_s do return string(s)
			}
		}
	}
	if v, ok := obj[key]; ok {
		if s, is_s := v.(json.String); is_s do return string(s)
	}
	return ""
}

task_status_str :: proc(st: domain.Task_Status) -> string {
	switch st {
	case .Assigned: return "assigned"
	case .Queued: return "queued"
	case .In_Progress: return "in_progress"
	case .In_Validation: return "in_validation"
	case .Validated_Good: return "validated_good"
	case .Validated_Not_Good: return "validated_not_good"
	case .Paused: return "paused"
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	}
	return "assigned"
}

chain_status_str :: proc(st: domain.Task_Chain_Status) -> string {
	switch st {
	case .Active: return "active"
	case .Completed: return "completed"
	case .Cancelled: return "cancelled"
	}
	return "active"
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
	cards:       ^iface.Card_Repository,
	projects:    ^iface.Project_Repository,
	taskchains:  ^taskchain_service.Taskchain_Service,
	content:     ^content_service.Content_Service,
	project_svc: ^project_service.Project_Service,
	uow_factory: ^iface.Unit_Of_Work_Factory,
	clock:       ^platform.Clock,
	ids:         ^platform.ID_Generator,
}

new_card_service :: proc(
	cards:       ^iface.Card_Repository,
	projects:    ^iface.Project_Repository,
	taskchains:  ^taskchain_service.Taskchain_Service = nil,
	content:     ^content_service.Content_Service = nil,
	project_svc: ^project_service.Project_Service = nil,
	uow_factory: ^iface.Unit_Of_Work_Factory = nil,
	clock:       ^platform.Clock = nil,
	ids:         ^platform.ID_Generator = nil,
) -> Card_Service {
	return Card_Service{
		cards       = cards,
		projects    = projects,
		taskchains  = taskchains,
		content     = content,
		project_svc = project_svc,
		uow_factory = uow_factory,
		clock       = clock,
		ids         = ids,
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
	if status != domain.CARD_STATUS_SNOOZED {
		status = domain.CARD_STATUS_PENDING
	}

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

sync_projected_cards :: proc(s: ^Card_Service, owner: domain.User_ID) {
	if s == nil || s.cards == nil do return
	now := platform.clock_now(s.clock)

	// 1. Task-in-validation deterministic provider
	if s.taskchains != nil && s.taskchains.repo != nil {
		chains, cerr := iface.taskchain_list_chains_by_owner(s.taskchains.repo, owner)
		if cerr.code == .None {
			defer delete(chains)
			for chain in chains {
				tasks, terr := iface.taskchain_list_tasks_by_chain(s.taskchains.repo, chain.chain_id, owner)
				if terr.code != .None do continue
				defer delete(tasks)

				for task in tasks {
					if task.status != .In_Validation do continue

					// Only surface tasks that AWAIT THE USER: skip any task that has an
					// agent reviewer (that agent will vote on it). Empty / user-only
					// reviewer_refs yields 0 instances => still projected.
					task_reviewers := taskchain_service.extract_instances_from_ref_blob(task.reviewer_refs_json)
					has_agent_reviewer := len(task_reviewers) > 0
					delete(task_reviewers)
					if has_agent_reviewer do continue

					cid := domain.Card_ID(fmt.tprintf("crd_task_%s", string(task.task_id)))
					existing, exists, _ := iface.card_get(s.cards, cid)
					if exists {
						// Preserve user's explicit status changes
						if existing.status == domain.CARD_STATUS_SNOOZED {
							if existing.snooze_until != "" && existing.snooze_until <= now {
								_, _ = iface.card_update_status(s.cards, cid, domain.CARD_STATUS_PENDING, now)
							}
						}
						continue
					}

					t_title := task.title
					if t_title == "" do t_title = string(task.task_id)
					c_title := chain.title
					if c_title == "" do c_title = string(chain.chain_id)

					title := fmt.tprintf("Review task: %s", t_title)
					rationale := fmt.tprintf("Task %s in chain \"%s\" is in validation and awaiting review", string(task.task_id), c_title)

					b_ops := strings.builder_make()
					strings.write_string(&b_ops, `[{"op":"task.vote","label":"`)
					contracts.write_json_string(&b_ops, fmt.tprintf("Cast LGTM on task: %s", t_title))
					strings.write_string(&b_ops, `","args":{"task_id":"`)
					contracts.write_json_string(&b_ops, string(task.task_id))
					strings.write_string(&b_ops, `","result":"lgtm"}}]`)

					b_guard := strings.builder_make()
					strings.write_string(&b_guard, `{"task_id":"`)
					contracts.write_json_string(&b_guard, string(task.task_id))
					strings.write_string(&b_guard, `","expected_status":"in_validation"}`)

					b_refs := strings.builder_make()
					strings.write_string(&b_refs, `[{"type":"task","id":"`)
					contracts.write_json_string(&b_refs, string(task.task_id))
					strings.write_string(&b_refs, `"}]`)

					card := domain.Card{
						card_id          = cid,
						owner_user_id    = owner,
						project_id       = domain.Project_ID(""),
						title            = title,
						rationale        = rationale,
						scope            = domain.CARD_SCOPE_TASK,
						provider         = domain.CARD_PROVIDER_TASK_VALIDATION,
						confidence       = 1.0,
						source_refs_json = strings.to_string(b_refs),
						status           = domain.CARD_STATUS_PENDING,
						operations_json  = strings.to_string(b_ops),
						guard_json       = strings.to_string(b_guard),
						created_at       = now,
						updated_at       = now,
					}
					_, _, _ = iface.card_create(s.cards, card)
				}
			}
		}
	}

	// 2. Memory-proposal deterministic provider
	if s.content != nil && s.content.content != nil {
		mems, merr := iface.content_list_memories(s.content.content, owner)
		if merr.code == .None {
			defer delete(mems)
			for m in mems {
				if m.status != "pending" do continue

				cid := domain.Card_ID(fmt.tprintf("crd_mem_%s", m.memory_id))
				existing, exists, _ := iface.card_get(s.cards, cid)
				if exists {
					if existing.status == domain.CARD_STATUS_SNOOZED {
						if existing.snooze_until != "" && existing.snooze_until <= now {
							_, _ = iface.card_update_status(s.cards, cid, domain.CARD_STATUS_PENDING, now)
						}
					}
					continue
				}

				m_title := m.title
				if m_title == "" do m_title = "memory proposal"
				title := fmt.tprintf("Review memory proposal: %s", m_title)
				rationale := m.description if m.description != "" else m.body
				pid: domain.Project_ID = ""
				if len(m.project_ids) > 0 do pid = m.project_ids[0]

				b_ops := strings.builder_make()
				strings.write_string(&b_ops, `[{"op":"memory.approve","label":"`)
				contracts.write_json_string(&b_ops, fmt.tprintf("Approve memory proposal: %s", m_title))
				strings.write_string(&b_ops, `","args":{"memory_id":"`)
				contracts.write_json_string(&b_ops, m.memory_id)
				strings.write_string(&b_ops, `"}}]`)

				b_guard := strings.builder_make()
				strings.write_string(&b_guard, `{"memory_proposal_id":"`)
				contracts.write_json_string(&b_guard, m.memory_id)
				strings.write_string(&b_guard, `","expected_status":"pending"}`)

				b_refs := strings.builder_make()
				strings.write_string(&b_refs, `[{"type":"memory","id":"`)
				contracts.write_json_string(&b_refs, m.memory_id)
				strings.write_string(&b_refs, `"}]`)

				card := domain.Card{
					card_id          = cid,
					owner_user_id    = owner,
					project_id       = pid,
					title            = title,
					rationale        = rationale,
					scope            = domain.CARD_SCOPE_MEMORY,
					provider         = domain.CARD_PROVIDER_MEMORY_PROPOSAL,
					confidence       = 1.0,
					source_refs_json = strings.to_string(b_refs),
					status           = domain.CARD_STATUS_PENDING,
					operations_json  = strings.to_string(b_ops),
					guard_json       = strings.to_string(b_guard),
					created_at       = now,
					updated_at       = now,
				}
				_, _, _ = iface.card_create(s.cards, card)
			}
		}
	}
}

evaluate_guard :: proc(s: ^Card_Service, owner: domain.User_ID, card: domain.Card) -> (bool, string) {
	if s == nil do return true, ""
	now := platform.clock_now(s.clock)

	// TTL check
	if card.ttl_at != "" && card.ttl_at <= now {
		return false, "card TTL has expired"
	}

	trimmed_guard := strings.trim_space(card.guard_json)
	if trimmed_guard == "" || trimmed_guard == "{}" do return true, ""

	val, err := json.parse_string(trimmed_guard)
	if err != .None do return false, "invalid guard JSON"
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj do return false, "guard must be a JSON object"

	task_id := json_obj_string(obj, "task_id")
	expected_status := json_obj_string(obj, "expected_status")

	if task_id != "" {
		if s.taskchains == nil || s.taskchains.repo == nil do return false, "task repository not configured"
		task, task_ok, _ := iface.taskchain_get_task(s.taskchains.repo, domain.Task_ID(task_id))
		if !task_ok || task.owner_user_id != owner {
			return false, "referenced task does not exist"
		}
		if expected_status != "" {
			actual_status := task_status_str(task.status)
			if actual_status != expected_status {
				return false, fmt.tprintf("task status is %s, expected %s", actual_status, expected_status)
			}
		}
		// Consistency with sync_projected_cards: a task card only belongs on the
		// user's feed while the task awaits the user. Once an agent reviewer is
		// assigned the card is stale (that agent will vote, not the user).
		reviewers := taskchain_service.extract_instances_from_ref_blob(task.reviewer_refs_json)
		has_agent_reviewer := len(reviewers) > 0
		delete(reviewers)
		if has_agent_reviewer {
			return false, "task now has an agent reviewer"
		}
	}

	mem_id := json_obj_string(obj, "memory_proposal_id")
	if mem_id == "" do mem_id = json_obj_string(obj, "memory_id")
	if mem_id != "" {
		if s.content == nil || s.content.content == nil do return false, "content repository not configured"
		mem, mem_ok, _ := iface.content_get_memory(s.content.content, mem_id)
		if !mem_ok || (mem.owner_user_id != "system" && mem.owner_user_id != owner) {
			return false, "referenced memory does not exist"
		}
		if expected_status != "" {
			if mem.status != expected_status {
				return false, fmt.tprintf("memory status is %s, expected %s", mem.status, expected_status)
			}
		}
	}

	chain_id := json_obj_string(obj, "chain_id")
	if chain_id != "" {
		if s.taskchains == nil || s.taskchains.repo == nil do return false, "taskchain repository not configured"
		chain, chain_ok, _ := iface.taskchain_get_chain(s.taskchains.repo, domain.Task_Chain_ID(chain_id))
		if !chain_ok || chain.owner_user_id != owner {
			return false, "referenced chain does not exist"
		}
		if expected_status != "" {
			actual_status := chain_status_str(chain.status)
			if actual_status != expected_status {
				return false, fmt.tprintf("chain status is %s, expected %s", actual_status, expected_status)
			}
		}
	}

	return true, ""
}

get_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	owner, aok, aerr := ownership.owner_from_auth(auth)
	if !aok do return domain.Card{}, false, aerr

	c, ok, err := iface.card_get(s.cards, id)
	if !ok {
		id_str := string(id)
		if strings.has_prefix(id_str, "crd_task_") || strings.has_prefix(id_str, "crd_mem_") {
			sync_projected_cards(s, owner)
			c, ok, err = iface.card_get(s.cards, id)
			if !ok do return domain.Card{}, false, err
		} else {
			return domain.Card{}, false, err
		}
	}

	if ok2, e := ownership.require_owner(auth, c.owner_user_id); !ok2 {
		return domain.Card{}, false, e
	}
	return c, true, domain.Domain_Error{}
}

list_cards :: proc(s: ^Card_Service, auth: contracts.Auth_Context, filter: Card_Filter = {}, limit: int = 50) -> ([]domain.Card, domain.Domain_Error) {
	owner, ok, err := ownership.owner_from_auth(auth)
	if !ok do return nil, err

	sync_projected_cards(s, owner)

	all, list_err := iface.card_list(s.cards, owner)
	if list_err.code != .None do return nil, list_err
	defer delete(all)

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = 50
	if eff_limit > 200 do eff_limit = 200

	filtered := make([dynamic]domain.Card, 0, len(all))
	defer delete(filtered)
	now := platform.clock_now(s.clock)

	for c in all {
		card := c
		if card.status == domain.CARD_STATUS_PENDING {
			guard_ok, _ := evaluate_guard(s, owner, card)
			if !guard_ok {
				_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_DISCARDED, now)
				card.status = domain.CARD_STATUS_DISCARDED
				continue
			}
		}

		if filter.status != "" && card.status != filter.status do continue
		if filter.scope != "" && card.scope != filter.scope do continue
		if filter.provider != "" && card.provider != filter.provider do continue
		if filter.project_id != "" && card.project_id != filter.project_id do continue
		append(&filtered, card)
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

	sync_projected_cards(s, owner)

	all, list_err := iface.card_list_by_project(s.cards, project_id)
	if list_err.code != .None do return nil, list_err
	defer delete(all)

	filtered := make([dynamic]domain.Card, 0, len(all))
	defer delete(filtered)
	now := platform.clock_now(s.clock)

	for c in all {
		if c.owner_user_id != owner do continue
		card := c
		if card.status == domain.CARD_STATUS_PENDING {
			guard_ok, _ := evaluate_guard(s, owner, card)
			if !guard_ok {
				_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_DISCARDED, now)
				continue
			}
		}
		append(&filtered, card)
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
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	if card.status != domain.CARD_STATUS_PENDING && card.status != domain.CARD_STATUS_SNOOZED {
		return domain.Card{}, false, domain.domain_error(.Conflict, fmt.tprintf("card cannot be rejected in status '%s'", card.status))
	}

	user_auth := contracts.Auth_Context{
		kind    = .User_Token,
		user_id = string(card.owner_user_id),
	}

	// For provider cards, execute negative action:
	if card.provider == domain.CARD_PROVIDER_TASK_VALIDATION {
		task_id := domain.Task_ID(strings.trim_prefix(string(card.card_id), "crd_task_"))
		if s.taskchains != nil {
			_, vote_ok, vote_err := taskchain_service.record_task_vote(s.taskchains, user_auth, taskchain_service.Vote_Input{
				task_id = task_id,
				vote    = "ngtm",
				comment = "Rejected via Action Card",
			})
			if !vote_ok do return domain.Card{}, false, vote_err
		}
	} else if card.provider == domain.CARD_PROVIDER_MEMORY_PROPOSAL {
		mem_id := strings.trim_prefix(string(card.card_id), "crd_mem_")
		if s.content != nil {
			_, rej_ok, rej_err := content_service.reject_memory(s.content, user_auth, mem_id)
			if !rej_ok do return domain.Card{}, false, rej_err
		}
	}

	return update_card_status(s, auth, id, domain.CARD_STATUS_REJECTED)
}

accept_card :: proc(s: ^Card_Service, auth: contracts.Auth_Context, id: domain.Card_ID) -> (domain.Card, bool, domain.Domain_Error) {
	card, ok, err := get_card(s, auth, id)
	if !ok do return domain.Card{}, false, err

	if card.status != domain.CARD_STATUS_PENDING && card.status != domain.CARD_STATUS_SNOOZED {
		return domain.Card{}, false, domain.domain_error(.Conflict, fmt.tprintf("card cannot be accepted in status '%s'", card.status))
	}

	// Re-check guard against live state
	guard_ok, guard_reason := evaluate_guard(s, card.owner_user_id, card)
	if !guard_ok {
		now := platform.clock_now(s.clock)
		_, _ = iface.card_update_status(s.cards, card.card_id, domain.CARD_STATUS_DISCARDED, now)
		return domain.Card{}, false, domain.domain_error(.Conflict, fmt.tprintf("card precondition changed: %s", guard_reason))
	}

	trimmed_ops := strings.trim_space(card.operations_json)
	if trimmed_ops == "" || trimmed_ops == "[]" {
		now := platform.clock_now(s.clock)
		card.status = domain.CARD_STATUS_ACCEPTED
		card.updated_at = now
		saved, save_ok, save_err := iface.card_update(s.cards, card)
		return saved, save_ok, save_err
	}

	ops_val, ops_err := json.parse_string(trimmed_ops)
	if ops_err != .None {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "invalid operations JSON")
	}
	defer json.destroy_value(ops_val)

	ops_arr, is_arr := ops_val.(json.Array)
	if !is_arr {
		return domain.Card{}, false, domain.domain_error(.Validation_Failed, "operations must be a JSON array")
	}

	has_uow := s.uow_factory != nil
	uow: iface.Unit_Of_Work
	if has_uow {
		var_uow, uow_ok, uow_err := iface.unit_of_work_begin(s.uow_factory)
		if !uow_ok do return domain.Card{}, false, uow_err
		uow = var_uow
	}

	user_auth := contracts.Auth_Context{
		kind    = .User_Token,
		user_id = string(card.owner_user_id),
	}

	for elem in ops_arr {
		op_obj, is_obj := elem.(json.Object)
		if !is_obj {
			if has_uow do iface.unit_of_work_rollback(&uow)
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, "each operation must be a JSON object")
		}

		op_name := json_obj_string(op_obj, "op")

		switch op_name {
		case "task.vote":
			tid := op_arg_string(op_obj, "task_id")
			result := op_arg_string(op_obj, "result")
			comment := op_arg_string(op_obj, "comment")
			if result == "" do result = "lgtm"
			if comment == "" do comment = "Accepted via Action Card"
			if s.taskchains == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
			}
			_, v_ok, v_err := taskchain_service.record_task_vote(s.taskchains, user_auth, taskchain_service.Vote_Input{
				task_id = domain.Task_ID(tid),
				vote    = result,
				comment = comment,
			})
			if !v_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, v_err
			}

		case "memory.approve":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, m_ok, m_err := content_service.approve_memory(s.content, user_auth, mid)
			if !m_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, m_err
			}

		case "memory.reject":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, m_ok, m_err := content_service.reject_memory(s.content, user_auth, mid)
			if !m_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, m_err
			}

		case "memory.create":
			title := op_arg_string(op_obj, "title")
			body := op_arg_string(op_obj, "body")
			type_str := op_arg_string(op_obj, "type")
			description := op_arg_string(op_obj, "description")
			evidence := op_arg_string(op_obj, "evidence")
			typ := domain.memory_type_from_string(type_str)
			if typ == .Unknown do typ = .Fact
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, cr_ok, cr_err := content_service.create_memory(s.content, user_auth, content_service.Memory_Input{
				title       = title,
				body        = body,
				type        = typ,
				description = description,
				evidence    = evidence,
				status      = "active",
			})
			if !cr_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, cr_err
			}

		case "memory.delete", "memory.archive":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, a_ok, a_err := content_service.archive_memory(s.content, user_auth, mid)
			if !a_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, a_err
			}

		case "memory.update":
			mid := op_arg_string(op_obj, "memory_id")
			if mid == "" do mid = op_arg_string(op_obj, "id")
			title := op_arg_string(op_obj, "title")
			body := op_arg_string(op_obj, "body")
			description := op_arg_string(op_obj, "description")
			evidence := op_arg_string(op_obj, "evidence")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			_, u_ok, u_err := content_service.update_memory(s.content, user_auth, mid, content_service.Memory_Update_Input{
				title           = title,
				has_title       = title != "",
				body            = body,
				has_body        = body != "",
				description     = description,
				has_description = description != "",
				evidence        = evidence,
				has_evidence    = evidence != "",
			})
			if !u_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, u_err
			}

		case "task_chain.set_status":
			cid := op_arg_string(op_obj, "chain_id")
			if cid == "" do cid = op_arg_string(op_obj, "id")
			st_str := op_arg_string(op_obj, "status")
			if s.taskchains == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "taskchain service is not configured")
			}
			st := taskchain_service.chain_status_from_string(st_str)
			_, ch_ok, ch_err := taskchain_service.change_chain_status(s.taskchains, user_auth, domain.Task_Chain_ID(cid), st)
			if !ch_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, ch_err
			}

		case "project.update":
			pid := op_arg_string(op_obj, "project_id")
			if pid == "" do pid = op_arg_string(op_obj, "id")
			name := op_arg_string(op_obj, "name")
			desc := op_arg_string(op_obj, "description")
			if s.project_svc == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "project service is not configured")
			}
			_, pr_ok, pr_err := project_service.update(s.project_svc, user_auth, domain.Project_ID(pid), project_service.Update_Project_Input{
				name        = name,
				description = desc,
			})
			if !pr_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, pr_err
			}

		case "agent.prompt":
			iid := op_arg_string(op_obj, "instance_id")
			if iid == "" do iid = op_arg_string(op_obj, "agent_instance_id")
			prompt := op_arg_string(op_obj, "prompt")
			if prompt == "" do prompt = op_arg_string(op_obj, "prompt_text")
			if prompt == "" do prompt = op_arg_string(op_obj, "body")
			if s.content == nil {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, domain.domain_error(.Internal_Error, "content service is not configured")
			}
			conv, conv_ok, conv_err := content_service.get_conversation_by_instance(s.content, user_auth, iid)
			if !conv_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, conv_err
			}
			_, snd_ok, snd_err := content_service.send_message(s.content, user_auth, conv.conversation_id, content_service.Message_Input{
				body         = prompt,
				message_type = "action",
			})
			if !snd_ok {
				if has_uow do iface.unit_of_work_rollback(&uow)
				return domain.Card{}, false, snd_err
			}

		case:
			if has_uow do iface.unit_of_work_rollback(&uow)
			return domain.Card{}, false, domain.domain_error(.Validation_Failed, fmt.tprintf("unsupported card operation: %s", op_name))
		}
	}

	if has_uow {
		commit_ok, commit_err := iface.unit_of_work_commit(&uow)
		if !commit_ok do return domain.Card{}, false, commit_err
	}

	now := platform.clock_now(s.clock)
	card.status = domain.CARD_STATUS_ACCEPTED
	card.updated_at = now
	saved_card, save_ok, save_err := iface.card_update(s.cards, card)
	if !save_ok do return domain.Card{}, false, save_err
	return saved_card, true, domain.Domain_Error{}
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
