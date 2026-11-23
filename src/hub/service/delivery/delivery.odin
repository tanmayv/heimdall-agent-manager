package delivery

import "base:runtime"
import retry "odin_test:hub/service/pipelineretry"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"
import nats "odin_test:lib/nats"

LIFETIME_PROMPT :: time.Hour
LIFETIME_NOTICE :: 5 * time.Minute
LIFETIME_FLOW :: 24 * time.Hour
STREAM :: "HEIM_DELIVER"
ADVISORY_STREAM :: "HEIM_DELIVER_ADVISORIES"
ADVISORY_CONSUMER :: "hub_delivery_dlq"

Route_Input :: struct {
	kind, owner_user_id, bridge_id, agent_instance_id: string,
	cause, ref, conversation_id, message_id:           string,
	notice_line:                                       string,
	notice_count:                                      int,
	payload:                                           string,
	lifetime:                                          time.Duration,
	round:                                             int,
	excluded_bridges:                                  []string,
}
Replace_Why :: enum {
	Bridge_Offline,
	Fatal_Answer,
	Downgrade,
}
Sink :: struct {
	ctx:         rawptr,
	kind:        string,
	on_final:    proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) -> domain.Domain_Error,
	still_valid: proc(ctx: rawptr, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) -> bool,
	replace:     proc(
		ctx: rawptr,
		uow: ^iface.Unit_Of_Work,
		d: domain.Pipeline_Delivery,
		why: Replace_Why,
	) -> (
		bool,
		domain.Domain_Error,
	),
}
Answer_Op :: enum {
	Ack,
	Nak_Delay,
	In_Progress,
	Term,
}
Answer :: struct {
	op:       Answer_Op,
	reply:    string,
	delay_ms: i64,
}
Forwarder :: struct {
	service:                   ^Service,
	bridge_id:                 string,
	worker:                    ^thread.Thread,
	wake:                      sync.Sema,
	lifecycle:                 sync.Mutex, // start/join only; never taken by a NATS thread
	mutex:                     sync.Mutex,
	answers:                   [dynamic]Answer,
	// conn_lock protects pull. Only supervisor clears it on reconnect.
	pull:                      ^nats.Pull,
	// Supervisor deletes the consumer; callbacks only set these flags.
	disabled, delete_consumer: i32,
}
Service :: struct {
	diagnostics: retry.State,
	factory:                              ^iface.Unit_Of_Work_Factory,
	bridges:                              ^iface.Bridge_Repository,
	registry:                             ^project.Bridge_Runtime_Registry,
	commands:                             ^project.Bridge_Command_Sink,
	clock:                                ^platform.Clock,
	ids:                                  ^platform.ID_Generator,
	options:                              nats.Connect_Options,
	sinks:                                [dynamic]Sink,
	mutex:                                sync.Mutex,
	forwarders:                           [dynamic]^Forwarder,
	consumer_deletions:                   [dynamic]string,
	refused_bridges:                      [dynamic]string,
	worker:                               ^thread.Thread,
	wake:                                 sync.Sema,
	conn_lock:                            sync.RW_Mutex,
	conn:                                 ^nats.Connection,
	connected:                            bool,
	stopping, reconnect:                  i32,
	last_prune_ms:                        i64,
	prune_count:                          i64,
	forwarders_refused, invalid_messages: i64,
	// Defaults are production constants. Tests may shorten these before start.
	ack_wait_ms:                          i64,
	max_deliver:                          int,
}

new_service :: proc(
	factory: ^iface.Unit_Of_Work_Factory,
	bridges: ^iface.Bridge_Repository,
	registry: ^project.Bridge_Runtime_Registry,
	commands: ^project.Bridge_Command_Sink,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	options: nats.Connect_Options,
) -> ^Service {
	s := new(Service, runtime.heap_allocator())
	s.factory =
		factory; s.bridges = bridges; s.registry = registry; s.commands = commands; s.clock = clock; s.ids = ids
	s.options = options
	s.options.url = strings.clone(options.url, runtime.heap_allocator())
	s.options.creds_file = strings.clone(options.creds_file, runtime.heap_allocator())
	s.options.ca_file = strings.clone(options.ca_file, runtime.heap_allocator())
	s.sinks = make([dynamic]Sink, runtime.heap_allocator())
	s.forwarders = make([dynamic]^Forwarder, runtime.heap_allocator())
	s.consumer_deletions = make([dynamic]string, runtime.heap_allocator())
	s.refused_bridges = make([dynamic]string, runtime.heap_allocator())
	s.ack_wait_ms = contracts.DELIVERY_ACK_WAIT_MS; s.max_deliver = contracts.DELIVERY_MAX_DELIVER
	return s
}

register_sink :: proc(s: ^Service, sink: Sink) {
	assert(s.worker == nil, "register sinks before start")
	for v in s.sinks do assert(v.kind != sink.kind, "duplicate delivery sink")
	owned := sink
	owned.kind = strings.clone(sink.kind, runtime.heap_allocator())
	append(&s.sinks, owned)
}

find_sink :: proc(s: ^Service, kind: string) -> Sink {
	for v in s.sinks do if v.kind == kind do return v
	return {}
}

bridge_capable :: proc(b: domain.Bridge) -> bool {
	features := jsonx.extract_string_array(b.capabilities_json, "features")
	defer {for f in features do delete(f); delete(features)}
	for f in features do if f == contracts.BRIDGE_FEATURE_EVENT_PIPELINE_V1 do return true
	return false
}

route :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, input: Route_Input) -> (string, domain.Domain_Error) {
	if !nats.subject_token(input.owner_user_id) ||
	   !nats.subject_token(input.bridge_id) ||
	   (input.kind != "prompt" && input.kind != "notice" && input.kind != "bot" && input.kind != "lease") ||
	   input.lifetime <= 0 ||
	   input.round < 0 ||
	   input.round >= domain.DELIVERY_MAX_ROUNDS {
		return "", domain.domain_error(.Validation_Failed, "invalid delivery route")
	}
	b, found, err := iface.bridge_get_bridge(s.bridges, input.bridge_id)
	if err.code != .None do return "", err
	if !found do return "", domain.domain_error(.Not_Found, "bridge not found")
	defer domain.bridge_destroy(&b)
	if b.owner_user_id != domain.User_ID(input.owner_user_id) do return "", domain.domain_error(.Not_Found, "bridge not found")
	if !bridge_capable(b) do return "", domain.domain_error(.Conflict, "bridge_too_old")
	now := platform.clock_now(s.clock)
	ms, valid := platform.rfc3339_to_unix_ms(now)
	if !valid do return "", domain.domain_error(.Internal_Error, "invalid delivery clock")
	expires := platform.format_rfc3339_utc(time.Time{_nsec = ms * 1_000_000 + i64(input.lifetime)})
	id := platform.generate_id(s.ids, contracts.DELIVERY_ID_PREFIX)
	excluded, je := json.marshal(input.excluded_bridges)
	if je != nil do return "", domain.domain_error(.Internal_Error, "invalid excluded bridges")
	defer delete(excluded)
	excluded_json := string(excluded)
	if len(input.excluded_bridges) == 0 do excluded_json = "[]"
	d := domain.Pipeline_Delivery {
		delivery_id           = id,
		owner_user_id         = input.owner_user_id,
		kind                  = input.kind,
		bridge_id             = input.bridge_id,
		agent_instance_id     = input.agent_instance_id,
		ref                   = input.ref,
		message_id            = input.message_id,
		state                 = domain.DELIVERY_ROUTED,
		round                 = input.round,
		excluded_bridges_json = excluded_json,
		expires_at            = expires,
		created_at            = now,
		updated_at            = now,
	}
	repo := &uow.repos.pipeline_deliveries
	err = repo.insert(repo.ctx, d)
	if err.code != .None do return "", err
	wire := contracts.Delivery_Wire {
		delivery_id = id,
		kind = input.kind,
		owner_user_id = input.owner_user_id,
		bridge_id = input.bridge_id,
		agent_instance_id = input.agent_instance_id,
		cause = input.cause,
		ref = input.ref,
		conversation_id = input.conversation_id,
		message_id = input.message_id,
		notice = {line = input.notice_line, count = input.notice_count},
		expires_at = expires,
		payload = input.payload,
	}
	body, be := json.marshal(wire)
	if be != nil do return "", domain.domain_error(.Internal_Error, "failed to encode delivery")
	defer delete(body)
	outbox := &uow.repos.event_outbox
	err = outbox.append(
		outbox.ctx,
		{
			event_id = id,
			owner_user_id = input.owner_user_id,
			subject = fmt.tprintf("dlv.%s.%s.%s", input.owner_user_id, input.bridge_id, input.kind),
			envelope_json = string(body),
			headers_json = "{}",
			created_at = now,
		},
	)
	if err.code != .None do return "", err
	return id, {}
}

retry_delay_ms :: proc(attempt: int, asked_ms: i64) -> i64 {
	shift := clamp(attempt - 1, 0, 5)
	return clamp(
		max(asked_ms, i64(contracts.DELIVERY_RETRY_MIN_MS) << uint(shift)),
		i64(contracts.DELIVERY_RETRY_MIN_MS),
		i64(contracts.DELIVERY_RETRY_MAX_MS),
	)
}

// Pass a copy: repository-owned string fields must remain destroyable after a transition.
close_delivery :: proc(
	s: ^Service,
	uow: ^iface.Unit_Of_Work,
	d: domain.Pipeline_Delivery,
	state, reason, outcome: string,
) -> (
	bool,
	domain.Domain_Error,
) {
	if !domain.pipeline_delivery_open(d.state) do return false, {}
	next := d
	next.state = state; next.reason = reason; next.outcome = outcome; next.updated_at = platform.clock_now(s.clock)
	repo := &uow.repos.pipeline_deliveries
	changed, err := repo.transition(repo.ctx, next, d.state)
	if err.code != .None || !changed do return false, err
	sink := find_sink(s, d.kind)
	if sink.on_final != nil {
		if err := sink.on_final(sink.ctx, uow, next); err.code != .None do return false, err
	}
	_ = iface.unit_of_work_after_commit(uow, {
		ctx = s,
		run = proc(ctx: rawptr) {prune_after_final((^Service)(ctx))},
	})
	return true, {}
}

expire :: proc(s:^Service,uow:^iface.Unit_Of_Work,delivery_id:string)->(bool,domain.Domain_Error) {
 repo:=&uow.repos.pipeline_deliveries
 d,found,err:=repo.get(repo.ctx,delivery_id)
 defer domain.pipeline_delivery_destroy(&d)
 if err.code!=.None do return false,err
 if !found || d.expires_at>platform.clock_now(s.clock) do return false,{}
 return close_delivery(s,uow,d,domain.DELIVERY_FAILED,"bridge_offline","")
}

prune :: proc(s: ^Service) {
	now, valid := platform.rfc3339_to_unix_ms(platform.clock_now(s.clock))
	if !valid do return
	uow, ok, _ := iface.unit_of_work_begin(s.factory)
	if !ok do return
	sync.atomic_add(&s.prune_count, 1)
	repo := &uow.repos.pipeline_deliveries
	cutoff := platform.format_rfc3339_utc(
		time.Time{_nsec = (now - i64(30 * 24 * time.Hour / time.Millisecond)) * 1_000_000},
	)
	err := repo.prune(repo.ctx, cutoff)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	_, _ = iface.unit_of_work_commit(&uow)
}

prune_after_final :: proc(s: ^Service) {
	now, valid := platform.rfc3339_to_unix_ms(platform.clock_now(s.clock))
	if !valid do return
	previous := sync.atomic_load(&s.last_prune_ms)
	if previous != 0 && now - previous < i64(time.Hour / time.Millisecond) do return
	_, won := sync.atomic_compare_exchange_strong(&s.last_prune_ms, previous, now)
	if won do prune(s)
}

expire_due :: proc(s: ^Service) {
	for {
		uow, ok, _ := iface.unit_of_work_begin(s.factory)
		if !ok do return
		repo := &uow.repos.pipeline_deliveries
		rows, err := repo.expired(repo.ctx, platform.clock_now(s.clock), 128)
		if err.code != .None {iface.unit_of_work_rollback(&uow); return}
		for d in rows {
			_, err = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "bridge_offline", "")
			if err.code != .None do break
		}
		count := len(rows)
		domain.pipeline_deliveries_destroy(rows)
		if err.code != .None {iface.unit_of_work_rollback(&uow); return}
		committed, _ := iface.unit_of_work_commit(&uow)
		if !committed do return
		if count < 128 do break
	}
	prune(s)
}
