package actions

import webhooks "odin_test:hub/service/webhooks"

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:fmt"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import placement "odin_test:hub/service/placement"

DEFAULT_MAX_PER_OWNER :: 1000
Schedule_Support_Port :: struct { ctx: rawptr, get: proc(ctx: rawptr) -> int }
Service :: struct {
 filter_limits: Filter_Limits,
 webhook_limits:webhooks.Limits,
 max_per_owner: int, // Zero selects DEFAULT_MAX_PER_OWNER.
	factory: ^iface.Unit_Of_Work_Factory,
	repos: ^iface.Repositories,
	placement: ^placement.Service,
	experiments: ^iface.Experiment_Repository,
	support: Schedule_Support_Port,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	target_kinds: []string,
}
Rule_Input :: struct { bridge_id, provider, model: string }
Target_Input :: struct {
	kind, agent_id, project_id, instance_id, bot_id, instance_strategy, selector: string,
	rules: []Rule_Input,
}
Trigger_Input :: struct { id, kind: string, config: json.Object, enabled: Maybe(bool), delay_s: Maybe(int) }
Action_Input :: struct {
	name, prompt_text: Maybe(string),
	enabled: Maybe(bool),
	min_interval_s: Maybe(int),
	target: Maybe(Target_Input),
	triggers: Maybe([]Trigger_Input),
}
Action_View :: struct { action: domain.Action, rules: []domain.Action_Target_Rule, triggers: []domain.Action_Trigger }
action_view_destroy :: proc(v: ^Action_View) {
	domain.action_destroy(&v.action)
	domain.action_rules_destroy(v.rules)
	domain.action_triggers_destroy(v.triggers)
	v^ = {}
}
action_views_destroy :: proc(rows: []Action_View) {
	for &row in rows do action_view_destroy(&row)
	delete(rows)
}
load_view :: proc(repo: ^iface.Action_Repository, owner, id: string) -> (Action_View, domain.Domain_Error) {
	a, found, err := repo.get(repo.ctx, domain.Action_ID(id))
	if err.code != .None { domain.action_destroy(&a); return {}, err }
	if !found || string(a.owner_user_id) != owner {
		domain.action_destroy(&a)
		return {}, domain.domain_error(.Not_Found, "action not found")
	}
	v := Action_View{action=a}
	rules, rules_err := repo.rules_list(repo.ctx, a.id)
	v.rules = rules
	if rules_err.code != .None { action_view_destroy(&v); return {}, rules_err }
	triggers, triggers_err := repo.triggers_list(repo.ctx, a.id)
	v.triggers = triggers
	if triggers_err.code != .None { action_view_destroy(&v); return {}, triggers_err }
	return v, {}
}
get :: proc(s: ^Service, owner, action_id: string) -> (Action_View, domain.Domain_Error) {
	uow, ok, err := iface.unit_of_work_begin(s.factory)
	if !ok do return {}, err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	v, read_err := load_view(&uow.repos.actions, owner, action_id)
	if read_err.code != .None do return {}, read_err
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed { action_view_destroy(&v); return {}, commit_err }
	return v, {}
}
list :: proc(s: ^Service, owner: string) -> ([]Action_View, domain.Domain_Error) {
	uow, ok, err := iface.unit_of_work_begin(s.factory)
	if !ok do return nil, err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	repo := &uow.repos.actions
	rows, read_err := repo.list(repo.ctx, domain.User_ID(owner))
	defer { for &row in rows do domain.action_destroy(&row); delete(rows) }
	if read_err.code != .None do return nil, read_err
	views := make([]Action_View, len(rows))
	success := false
	defer if !success do action_views_destroy(views)
 index:=make(map[string]int)
 defer delete(index)
 for row,i in rows {
  views[i].action=row
  index[string(row.id)]=i
  rows[i]={}
 }
 rules,rules_err:=repo.rules_for_owner(repo.ctx,owner)
 defer {
  for row in rules {delete(row.action_id);delete(row.rule.bridge_id);delete(row.rule.provider);delete(row.rule.model)}
  delete(rules)
 }
 if rules_err.code!=.None do return nil,rules_err
 grouped_rules:=make([][dynamic]domain.Action_Target_Rule,len(views))
 defer delete(grouped_rules)
 for &row in rules {
  if i,found:=index[row.action_id];found {
   append(&grouped_rules[i],row.rule);row.rule={}
  }
 }
 for i in 0..<len(views) do views[i].rules=grouped_rules[i][:]
 triggers,triggers_err:=repo.triggers_for_owner(repo.ctx,owner)
 defer domain.action_triggers_destroy(triggers)
 if triggers_err.code!=.None do return nil,triggers_err
 grouped_triggers:=make([][dynamic]domain.Action_Trigger,len(views))
 defer delete(grouped_triggers)
 for &row in triggers {
  if i,found:=index[string(row.action_id)];found {
   append(&grouped_triggers[i],row);row={}
  }
 }
 for i in 0..<len(views) do views[i].triggers=grouped_triggers[i][:]
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed do return nil, commit_err
	success = true
	return views, {}
}
schedule_supported :: proc(s: ^Service) -> bool {
	return s.support.get == nil || s.support.get(s.support.ctx) != 2
}

// Validation reads use a scoped arena; repository records cannot escape it.
validate_target :: proc(s: ^Service, repos: ^iface.Repositories, owner: string, target: Target_Input) -> domain.Domain_Error {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	allowed := false
	for kind in s.target_kinds do if kind == target.kind { allowed = true; break }
	if !allowed do return detail_error("target_kind_unavailable")
	if target.kind != domain.ACTION_TARGET_AGENT && len(target.rules) > 0 do return detail_error("rules_not_allowed")
	switch target.kind {
	case domain.ACTION_TARGET_AGENT:
		a, found, e := iface.agent_get(&repos.agents, target.agent_id)
		if e.code != .None do return e
		if !found || string(a.owner_user_id) != owner do return domain.domain_error(.Not_Found, "agent not found")
		if target.project_id != "" {
			p, exists, pe := iface.project_get(&repos.projects, domain.Project_ID(target.project_id))
			if pe.code != .None do return pe
			if !exists || string(p.owner_user_id) != owner do return domain.domain_error(.Not_Found, "project not found")
		}
		if !domain.action_instance_strategy_valid(target.instance_strategy) do return detail_error("invalid_strategy")
		selector := target.selector
		if selector == "" do selector = "first"
		_, exists := placement.selector_find(s.placement, selector)
		if !exists do return detail_error("unknown_selector")
		rules := make([]placement.Rule, len(target.rules))
		for rule, i in target.rules do rules[i] = {position=i, bridge_id=rule.bridge_id, provider=rule.provider, model=rule.model}
		if e := placement.validate_rules(s.placement, owner, rules, domain.ACTION_MAX_RULES); e.code != .None {
			if e.code == .Validation_Failed do return detail_error(e.message)
			if e.code == .Not_Found {
				// Normalize missing references at the actions boundary (T9 ruling).
				// Placement retains its existing error contract for other callers.
				for rule in target.rules {
					if rule.bridge_id != placement.ANY {
						bridge, exists, err := iface.bridge_get_bridge(&repos.bridges, rule.bridge_id)
						if err.code != .None && err.code != .Not_Found do return err
						if !exists || err.code == .Not_Found || string(bridge.owner_user_id) != owner do return detail_error("unknown_bridge")
					}
					if rule.provider != placement.ANY {
						entry, exists, err := iface.provider_catalog_get(s.placement.providers.repo, rule.provider)
						_ = entry
						if err.code != .None && err.code != .Not_Found do return err
						if !exists || err.code == .Not_Found do return detail_error("unknown_provider")
					}
				}
			}
			return e
		}
	case domain.ACTION_TARGET_BOT:
		if !actions_gate_on(s.experiments, owner, "bots") do return detail_error("experiment_off")
		if target.instance_strategy != "" && target.instance_strategy != domain.ACTION_INSTANCE_STRATEGY_REUSE do return detail_error("strategy_not_allowed")
		bot, e := owned_bot(&repos.bots, owner, target.bot_id)
		if e.code != .None do return e
		_ = bot
	case domain.ACTION_TARGET_INSTANCE:
		inst, found, e := iface.agent_get_instance(&repos.agents, target.instance_id)
		if e.code != .None do return e
		if !found || string(inst.owner_user_id) != owner do return domain.domain_error(.Not_Found, "instance not found")
		_, bot_found, bot_err := iface.bot_get_by_instance(&repos.bots, target.instance_id)
		if bot_err.code != .None do return bot_err
		if bot_found do return detail_error("target_is_bot_instance")
	case:
		return detail_error("target_kind_unavailable")
	}
	return {}
}
validate_entity :: proc(repos:^iface.Repositories,owner:string,config:json.Object)->domain.Domain_Error {
 id,valid:=config_string(config,"entity_id")
 if !valid do return detail_error("unknown_entity")
 if id=="" do return {}
 event_type,_:=config_string(config,"event_type")
 descriptor:=event_descriptor_find(event_type)
 if descriptor==nil do return detail_error("unknown_event_type")
 if descriptor.validate_entity!=nil do return descriptor.validate_entity(repos,owner,id)
 arena:virtual.Arena
 if virtual.arena_init_growing(&arena)!=nil do return domain.domain_error(.Internal_Error,"entity validation unavailable")
 defer virtual.arena_destroy(&arena)
 context.allocator=virtual.arena_allocator(&arena)
 // Returned errors use the caller's request temp allocator, not this row arena.
 found:=false
 actual:=""
 err:domain.Domain_Error
 switch descriptor.scope {
 case "chain":
  row:domain.Task_Chain
  row,found,err=iface.taskchain_get_chain(&repos.taskchains,domain.Task_Chain_ID(id))
  actual=string(row.owner_user_id)
 case "task":
  row:domain.Task
  row,found,err=iface.taskchain_get_task(&repos.taskchains,domain.Task_ID(id))
  actual=string(row.owner_user_id)
 case "memory":
  row:domain.Memory
  row,found,err=iface.content_get_memory(&repos.content,id)
  actual=string(row.owner_user_id)
 case: return detail_error("unknown_entity")
 }
 if err.code!=.None && err.code!=.Not_Found do return err
 if !found || actual!=owner do return detail_error("unknown_entity")
 return {}
}

replace_string :: proc(dst: ^string, value: string) {
	delete(dst^)
	dst^ = strings.clone(value)
}
apply_target :: proc(a: ^domain.Action, t: Target_Input) {
	replace_string(&a.target_kind, t.kind)
	replace_string(cast(^string)&a.target_agent_id, t.agent_id)
	replace_string(cast(^string)&a.target_project_id, t.project_id)
	replace_string(cast(^string)&a.target_instance_id, t.instance_id)
	replace_string(&a.target_bot_id, t.bot_id)
	replace_string(&a.instance_strategy, t.instance_strategy if t.instance_strategy != "" else "reuse")
	replace_string(&a.placement_selector, t.selector if t.selector != "" else "first")
	replace_string(cast(^string)&a.last_spawned_instance_id, "")
}
create :: proc(s: ^Service, owner: string, in_: Action_Input, actor: string = "") -> (Action_View, domain.Domain_Error) {
	return write_action(s, owner, "", in_, true, actor)
}
update :: proc(s: ^Service, owner, action_id: string, in_: Action_Input, actor: string = "") -> (Action_View, domain.Domain_Error) {
	return write_action(s, owner, action_id, in_, false, actor)
}
set_enabled :: proc(s: ^Service, owner, action_id: string, enabled: bool) -> (Action_View, domain.Domain_Error) {
	return update(s, owner, action_id, Action_Input{enabled=enabled})
}
write_action :: proc(s: ^Service, owner, action_id: string, in_: Action_Input, creating: bool, actor: string) -> (Action_View, domain.Domain_Error) {
	uow, ok, begin_err := iface.unit_of_work_begin(s.factory)
	if !ok do return {}, begin_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	repo := &uow.repos.actions
	v: Action_View
	if !creating {
		loaded, err := load_view(repo, owner, action_id)
		if err.code != .None do return {}, err
		v = loaded
	} else {
  rows, count_err := repo.list(repo.ctx, domain.User_ID(owner))
  count := len(rows)
  for &row in rows do domain.action_destroy(&row)
  delete(rows)
  if count_err.code != .None do return {}, count_err
  limit := s.max_per_owner
  if limit <= 0 do limit = DEFAULT_MAX_PER_OWNER
  if count >= limit do return {}, domain.domain_error(.Conflict, "automation limit reached for this owner")
		v.action = {id=domain.Action_ID(strings.clone(platform.generate_id(s.ids, "act_"))),
			owner_user_id=domain.User_ID(strings.clone(owner)), enabled=true,
			min_interval_s=domain.ACTION_MIN_INTERVAL_DEFAULT_S,
			created_at=strings.clone(platform.clock_now(s.clock))}
	}
	defer action_view_destroy(&v)
	if creating do replace_string(&v.action.created_by, actor)
 replace_string(&v.action.updated_by, actor)
	old_enabled := v.action.enabled
	if value, present := in_.name.?; present do replace_string(&v.action.name, value)
	if value, present := in_.prompt_text.?; present do replace_string(&v.action.prompt_text, value)
	if value, present := in_.enabled.?; present do v.action.enabled = value
	if value, present := in_.min_interval_s.?; present do v.action.min_interval_s = value
	if strings.trim_space(v.action.prompt_text) == "" do return {}, detail_error("prompt_required")
	if v.action.min_interval_s < domain.ACTION_MIN_INTERVAL_MIN_S || v.action.min_interval_s > domain.ACTION_MIN_INTERVAL_MAX_S do return {}, detail_error("min_interval_out_of_range")
	target, target_present := in_.target.?
	if creating && !target_present do return {}, detail_error("target_kind_unavailable")
	if target_present {
		if err := validate_target(s, uow.repos, owner, target); err.code != .None do return {}, err
		apply_target(&v.action, target)
		domain.action_rules_destroy(v.rules)
		v.rules = make([]domain.Action_Target_Rule, len(target.rules))
		for rule, i in target.rules do v.rules[i] = {position=i, bridge_id=strings.clone(rule.bridge_id), provider=strings.clone(rule.provider), model=strings.clone(rule.model)}
	}
	replace_string(&v.action.updated_at, platform.clock_now(s.clock))
	// Validate all trigger replacements before writing any rows. Rollback also
	// covers errors from repositories and kind callbacks.
	inputs, replacing := in_.triggers.?
	if len(inputs) > domain.ACTION_MAX_TRIGGERS do return {}, detail_error("too_many_triggers")
	next: []domain.Action_Trigger
	defer domain.action_triggers_destroy(next)
	if replacing {
		next = make([]domain.Action_Trigger, len(inputs))
		for input, i in inputs {
			for previous in inputs[:i] do if input.id != "" && previous.id == input.id do return {}, detail_error("duplicate_trigger")
			kind, found := trigger_kind_find(input.kind)
			if !found do return {}, detail_error("unknown_trigger_kind")
			old: ^domain.Action_Trigger
			if input.id != "" {
				for &trigger in v.triggers do if trigger.trigger_id == input.id { old=&trigger; break }
				if creating || old == nil do return {}, domain.domain_error(.Not_Found, "trigger not found")
				if old.kind != input.kind do return {}, detail_error("trigger_kind_immutable")
			}
			id := input.id
			if id == "" do id = platform.generate_id(s.ids, "trg_")
			if input.kind == "event" {
				if err := validate_entity(uow.repos, owner, input.config); err.code != .None do return {}, err
			}
			spec:Match_Spec
   compile_err:domain.Domain_Error
   if input.kind=="event" {
    spec,compile_err=event_compile_limits(owner,string(v.action.id),id,input.config,filter_limits(s.filter_limits),context.allocator)
   } else {spec,compile_err=kind.compile(owner,string(v.action.id),id,input.config,context.allocator)}
			if compile_err.code != .None do return {}, compile_err
			encoded, encode_err := json.marshal(input.config, opt={sort_maps_by_key=true}, allocator=context.allocator)
			if encode_err != nil { match_spec_destroy(&spec); return {}, detail_error("invalid_config") }
			t := &next[i]
			t^ = {trigger_id=strings.clone(id), action_id=domain.Action_ID(strings.clone(string(v.action.id))),
				owner_user_id=domain.User_ID(strings.clone(owner)),kind=strings.clone(input.kind),config_json=string(encoded),
				event_type=spec.event_type,subject_filter=spec.subject_filter,data_filter_json=spec.data_filter_json,
				match_key=strings.clone(match_key(spec.subject_filter)), enabled=true, rev=1,
				created_at=strings.clone(v.action.updated_at),updated_at=strings.clone(v.action.updated_at)}
			if old != nil {
				t.enabled = old.enabled
				t.rev = old.rev
				replace_string(&t.created_at, old.created_at)
			}
			if old != nil do t.delay_s = old.delay_s
			if delay, present := input.delay_s.?; present do t.delay_s = delay
			if t.delay_s>0 && input.kind=="event" {
    descriptor:=event_descriptor_find(t.event_type)
    if descriptor!=nil && descriptor.no_delay do return {},detail_error("delay_not_supported")
   }
   if t.delay_s < 0 || t.delay_s > domain.ACTION_MAX_DELAY_S do return {}, detail_error("delay_out_of_range")
			if enabled, present := input.enabled.?; present do t.enabled = enabled
			if old != nil && (old.config_json != t.config_json || old.enabled != t.enabled || old.delay_s != t.delay_s || old_enabled != v.action.enabled) do t.rev += 1
		}
	} else {
		// Transfer ownership to next; v retains only the original action/rules.
		next = v.triggers
		v.triggers = nil
	}
	if err := repo.save(repo.ctx, v.action); err.code != .None do return {}, err
	if target_present {
		if err := repo.rules_replace(repo.ctx, v.action.id, v.rules); err.code != .None do return {}, err
	}
	sc := Sync_Context{outbox=&uow.repos.event_outbox, clock=s.clock, ids=s.ids}
	if replacing {
		for &old in v.triggers {
			retained := false
			for trigger in next do if trigger.trigger_id == old.trigger_id { retained=true; break }
			if retained do continue
			kind, found := trigger_kind_find(old.kind)
			if !found do return {}, detail_error("unknown_trigger_kind")
			before := old; before.enabled = before.enabled && old_enabled
			if kind.on_change != nil {
				if err := kind.on_change(&sc, &before, nil); err.code != .None do return {}, err
			}
			if err := repo.trigger_delete(repo.ctx, old.trigger_id); err.code != .None do return {}, err
		}
	}
	for &trigger in next {
		kind, _ := trigger_kind_find(trigger.kind)
		if kind == nil do return {}, detail_error("unknown_trigger_kind")
		before: domain.Action_Trigger
		before_ptr: ^domain.Action_Trigger
		if replacing {
			for old in v.triggers do if old.trigger_id == trigger.trigger_id { before=old; before_ptr=&before; break }
		} else {
			before = trigger
			before_ptr = &before
			if old_enabled != v.action.enabled {
				trigger.rev += 1
				replace_string(&trigger.updated_at, v.action.updated_at)
			}
		}
		if before_ptr != nil do before.enabled = before.enabled && old_enabled
		after := trigger
		after.enabled = after.enabled && v.action.enabled
		if (trigger.kind == "schedule" || trigger.delay_s > 0) && after.enabled && !schedule_supported(s) do return {}, domain.domain_error(.Conflict, "Scheduled triggers need nats-server 2.14 or newer.", "{\"code\":\"schedules_unsupported\"}")
		if err := repo.trigger_save(repo.ctx, trigger); err.code != .None do return {}, err
		if kind.on_change != nil {
			if err := kind.on_change(&sc, before_ptr, &after); err.code != .None do return {}, err
		}
	}
	result, read_err := load_view(repo, owner, string(v.action.id))
	if read_err.code != .None do return {}, read_err
	committed, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	if !committed { action_view_destroy(&result); return {}, commit_err }
	return result, {}
}
delete_action :: proc(s: ^Service, owner, action_id: string) -> domain.Domain_Error {
	uow, ok, err := iface.unit_of_work_begin(s.factory)
	if !ok do return err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	v, read_err := load_view(&uow.repos.actions, owner, action_id)
	if read_err.code != .None do return read_err
	defer action_view_destroy(&v)
	sc := Sync_Context{outbox=&uow.repos.event_outbox, clock=s.clock, ids=s.ids}
	for &trigger in v.triggers {
		kind, found := trigger_kind_find(trigger.kind)
		if !found do return detail_error("unknown_trigger_kind")
		trigger.enabled = trigger.enabled && v.action.enabled
		if kind.on_change != nil {
			if e := kind.on_change(&sc, &trigger, nil); e.code != .None do return e
		}
	}
	if e := uow.repos.actions.delete_action(uow.repos.actions.ctx, v.action.id); e.code != .None do return e
	_, commit_err := iface.unit_of_work_commit(&uow)
	uow.ctx = nil
	return commit_err
}

Trigger_Types_View :: struct {
	target_kinds: []string,
	schedules_supported: bool,
	limits: struct {
		max_triggers, max_rules, max_automations_per_owner: int,
  filter: Filter_Limits,
  webhook:webhooks.Limits,
		min_interval_s: struct {min,max,default:int},
	},
	trigger_kinds: []Trigger_Type_View,
}
Trigger_Type_View :: struct {
	kind, label: string,
	modes: []string `json:"modes,omitempty"`,
	events: []Event_Type_View `json:"events,omitempty"`,
}
Event_Type_View :: struct {
	event_type,label,scope:string,
 no_delay, free_data_paths:bool,
 fields:[]Filter_Field_View,
	presets:[]Event_Preset_View,
}
Event_Preset_View :: struct {id,label:string,filter:json.Object}
Filter_Field_View :: struct {field:string,operators:[]string,values:[]string}
// Metadata strings are borrowed. The returned slices/maps live in the pass
// temporary allocator and must be serialized before that allocator is reset.
trigger_types :: proc(s:^Service) -> Trigger_Types_View {
	kinds:=make([]Trigger_Type_View,len(TRIGGER_KINDS)+len(extra_trigger_kinds),context.temp_allocator)
	for kind,i in TRIGGER_KINDS do kinds[i]={kind=kind.kind,label=kind.kind}
	for kind,i in extra_trigger_kinds do kinds[len(TRIGGER_KINDS)+i]={kind=kind.kind,label=kind.kind}
	for &kind in kinds {
		switch kind.kind {
		case "schedule":
			kind.label="Schedule"
			kind.modes=make([]string,3,context.temp_allocator)
			copy(kind.modes,[]string{"cron","interval","once"})
		case "event":
			kind.label="Event"
			kind.events=make([]Event_Type_View,len(EVENT_DESCRIPTORS),context.temp_allocator)
			for descriptor,i in EVENT_DESCRIPTORS {
				event:=&kind.events[i]
				event^={event_type=descriptor.event_type,label=descriptor.label,scope=descriptor.scope,
					no_delay=descriptor.no_delay,free_data_paths=descriptor.free_data_paths,
     fields=make([]Filter_Field_View,3+len(descriptor.data_keys),context.temp_allocator),
     presets=make([]Event_Preset_View,len(descriptor.presets),context.temp_allocator)}
    for field,k in ([]string{"entity.id","entity.kind","actor"}) do event.fields[k]={field=field,operators=FILTER_OPERATORS}
    for field,k in descriptor.data_keys do event.fields[k+3]={field=fmt.tprintf("data.%s",field.key),operators=FILTER_OPERATORS,values=field.values}
				for preset,j in descriptor.presets {
					value:json.Value
					_ = json.unmarshal(transmute([]u8)preset.filter_json,&value,allocator=context.temp_allocator)
					data,_:=value.(json.Object)
					event.presets[j]={id=preset.id,label=preset.label,filter=data}
				}
			}
		}
	}
	return {target_kinds=s.target_kinds,schedules_supported=schedule_supported(s),
		limits={max_automations_per_owner=(s.max_per_owner if s.max_per_owner>0 else DEFAULT_MAX_PER_OWNER),filter=filter_limits(s.filter_limits),webhook=s.webhook_limits,max_triggers=domain.ACTION_MAX_TRIGGERS,max_rules=domain.ACTION_MAX_RULES,
			min_interval_s={min=domain.ACTION_MIN_INTERVAL_MIN_S,max=domain.ACTION_MIN_INTERVAL_MAX_S,default=domain.ACTION_MIN_INTERVAL_DEFAULT_S}},
		trigger_kinds=kinds}
}

// Returned records belong to the caller; validation uses its scoped arena.
owned_bot :: proc(repo: ^iface.Bot_Repository, owner, bot_id: string) -> (domain.Bot, domain.Domain_Error) {
 bot: domain.Bot
 found: bool
 err: domain.Domain_Error
 if bot_id == "" {bot, found, err = iface.bot_get_by_owner(repo, owner)} else {bot, found, err = iface.bot_get(repo, bot_id)}
 if err.code != .None do return bot, err
 if !found || bot.owner_user_id != owner do return bot, domain.domain_error(.Not_Found, "bot not found")
 return bot, {}
}

// Pure sample evaluation: borrows the request; returned text uses the pass allocator.
filter_test :: proc(s:^Service,input:contracts.Action_Filter_Test_Request)->contracts.Action_Filter_Test_Response {
 descriptor:=event_descriptor_find(input.event_type)
 if descriptor==nil do return {reason="unknown_event_type"}
 raw:=input.filter
 if raw==nil do raw=json.Object{}
 if _,null:=raw.(json.Null);null do raw=json.Object{}
 tree,e:=filter_compile(raw,descriptor,filter_limits(s.filter_limits),context.temp_allocator)
 defer filter_destroy(&tree,context.temp_allocator)
 if e.reason!="" do return {path=e.path,reason=e.reason}
 sample,ok:=input.event.(json.Object)
 if !ok do return {reason="invalid_event"}
 envelope:=sample
 if descriptor.free_data_paths {
  // A full envelope has type + entity. Otherwise the sample is a body.
  if _,full:=sample["entity"].(json.Object); !full {
   envelope=make(json.Object,context.temp_allocator)
   envelope["data"]=sample
  }
 }
 matched,nodes:=filter_evaluate(tree,envelope,true,context.temp_allocator)
 return {valid=true,matched=matched,nodes=nodes}
}
