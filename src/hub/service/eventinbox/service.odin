package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

Service :: struct {
	factory:     ^iface.Unit_Of_Work_Factory,
	notice_ctx: rawptr,
	// Called outside a UoW. True means the existing notice/start path accepted it.
	notice: proc(ctx: rawptr, owner, agent: string, target: domain.Event_Notice_Target, count: int, wake: bool) -> bool,
	options:     nats.Connect_Options,
	ids:         ^platform.ID_Generator,
	ack_wait:    time.Duration,
	max_deliver: i64,
}
subscription_rows_destroy :: proc(rows: []domain.Event_Subscription) {
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
}
delivery_rows_destroy :: proc(rows: []domain.Event_Delivery) {
	for &row in rows do domain.event_delivery_destroy(&row)
	delete(rows)
}
values_destroy :: proc(rows: []json.Value) {
	for row in rows do json.destroy_value(row)
	delete(rows)
}
unavailable :: proc() -> domain.Domain_Error {
	return domain.domain_error(.Internal_Error, "event queue unavailable")
}
subscriptions :: proc(
	s: ^Service,
	owner, agent: string,
) -> (
	rows: []domain.Event_Subscription,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	rows, err = uow.repos.event_subscriptions.list(uow.repos.event_subscriptions.ctx, owner, agent)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {subscription_rows_destroy(rows); return nil, commit_err}
	return
}
watch :: proc(s: ^Service, owner, agent, chain: string, remove: bool) -> domain.Domain_Error {
	if owner == "" || agent == "" do return domain.domain_error(.Forbidden, "agent identity required")
	subjects, valid := filters(owner, chain, "", "explicit")
	if !valid do return domain.domain_error(.Validation_Failed, "invalid chain")
	defer filters_destroy(subjects)
	encoded, enc_err := json.marshal(subjects)
	if enc_err != nil do return unavailable()
	defer delete(encoded)
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return begin_err
	// Validate ownership even on unwatch; never accept tenant ids from the body.
	repo := uow.repos.event_subscriptions
	owned, get_err := repo.owns_chain(repo.ctx, owner, chain)
	if get_err.code != .None {
		iface.unit_of_work_rollback(&uow)
		return get_err
	}
	if !owned {
		iface.unit_of_work_rollback(&uow)
		return domain.domain_error(.Not_Found, "chain not found")
	}
	err: domain.Domain_Error
	if remove {
		rows, list_err := repo.list(repo.ctx, owner, agent)
		err = list_err
		if err.code == .None {
			for row in rows {
				if row.chain_id == chain && row.source == "explicit" {
					err = repo.remove(repo.ctx, owner, agent, row.subscription_id)
					if err.code != .None do break
				}
			}
		}
		subscription_rows_destroy(rows)
	} else {
		id := platform.generate_id(s.ids, "sub_")
		if id == "" {iface.unit_of_work_rollback(&uow); return unavailable()}
		err = repo.put(
			repo.ctx,
			domain.Event_Subscription {
				subscription_id = id,
				owner_user_id = owner,
				subscriber_agent_id = agent,
				chain_id = chain,
				source = "explicit",
				filter_subjects = string(encoded),
				wake_policy = "catalog",
				consumer_name = id,
				created_at = platform.format_rfc3339_utc(time.now()),
			},
		)
	}
	if err.code != .None {iface.unit_of_work_rollback(&uow); return err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return commit_err
	return {}
}
ensure_consumer :: proc(s: ^Service, conn: ^nats.Connection, row: domain.Event_Subscription) -> bool {
	subjects: []string
	defer filters_destroy(subjects)
	if json.unmarshal(transmute([]byte)row.filter_subjects, &subjects) != nil do return false
	ack_wait := s.ack_wait
	if ack_wait <= 0 do ack_wait = 5 * time.Minute
	max_deliver := s.max_deliver
	if max_deliver <= 0 do max_deliver = 10
	err := nats.consumer_add(
		conn,
		{
			stream = "HEIM_EVENTS",
			durable = row.consumer_name,
			filter_subjects = subjects,
			ack_wait_ns = i64(ack_wait),
			max_deliver = max_deliver,
		},
	)
	return err.status == 0
}

ack_snapshot :: proc(
	s: ^Service,
	owner, agent: string,
	ids: []string,
) -> (
	rows: []domain.Event_Delivery,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	repo := uow.repos.event_subscriptions
	rows, err = repo.deliveries(repo.ctx, owner, agent, ids)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {delivery_rows_destroy(rows); return nil, commit_err}
	return
}
resolved_snapshot :: proc(
	s: ^Service,
	owner, agent: string,
	limit: int,
) -> (
	rows: []domain.Event_Delivery,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	repo := uow.repos.event_subscriptions
	rows, err = repo.resolutions(repo.ctx, owner, agent, limit)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed {delivery_rows_destroy(rows); return nil, commit_err}
	return
}

mark :: proc(s: ^Service, owner, agent: string, row: domain.Event_Delivery, resolved: bool) -> domain.Domain_Error {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return begin_err
	repo := uow.repos.event_subscriptions
	err := repo.mark_delivery(repo.ctx, owner, agent, row.subscription_id, row.event_id, resolved)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return commit_err
	return {}
}
acknowledge :: proc(s: ^Service, owner, agent: string, ids: []string) -> domain.Domain_Error {
	if owner == "" || agent == "" do return domain.domain_error(.Forbidden, "agent identity required")
	if len(ids) == 0 || len(ids) > 100 do return domain.domain_error(.Validation_Failed, "ack requires 1..100 event ids")
	rows, err := ack_snapshot(s, owner, agent, ids)
	if err.code != .None do return err
	defer delivery_rows_destroy(rows)
	// Validate the whole request before making any acknowledgement.
	for id in ids {
		found := false
		for row in rows do if row.event_id == id do found = true
		if !found do return domain.domain_error(.Not_Found, "event delivery not found")
	}
	conn, nerr := nats.connect(s.options)
	if nerr.status != 0 do return unavailable()
	defer nats.destroy(conn)
	for row in rows {
		wanted := false
		for id in ids do if id == row.event_id do wanted = true
		if !wanted || row.acknowledged do continue
		if nats.ack_reply(conn, row.ack_reply, 1000).status != 0 do return unavailable()
		if err = mark(s, owner, agent, row, false); err.code != .None do return err
	}
	return {}
}
is_stale :: proc(s: ^Service, owner, topic: string, generation: i64) -> (bool, domain.Domain_Error) {
	if topic == "" do return false, {}
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	stale, err := repo.stale(repo.ctx, owner, topic, generation)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	return stale, {}
}
// Freshness and recording share a transaction: a concurrent topic resolution
// cannot slip between a successful freshness read and the delivery decision.
record :: proc(s: ^Service, owner, agent: string, row: domain.Event_Delivery) -> (bool, domain.Domain_Error) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	stale := false
	err: domain.Domain_Error
	if row.topic_key != "" do stale, err = repo.stale(repo.ctx, owner, row.topic_key, row.topic_generation)
	if err.code == .None && !stale do err = repo.delivered(repo.ctx, owner, agent, row)
	if err.code == .Not_Found {iface.unit_of_work_rollback(&uow); return false, {}}
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	return !stale, {}
}

// Provisioning never trusts a pre-commit snapshot alone. If removal won the
// race, leave a durable deletion intent before trying immediate cleanup.
fence_consumer :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	row: domain.Event_Subscription,
) -> (
	bool,
	domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return false, begin_err
	repo := uow.repos.event_subscriptions
	live, err := repo.exists(repo.ctx, row.owner_user_id, row.subscriber_agent_id, row.subscription_id)
	if err.code == .None && !live do err = repo.queue_delete(repo.ctx, row.consumer_name)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false, err}
	committed, commit_err := iface.unit_of_work_commit(&uow)
	if !committed do return false, commit_err
	if live do return true, {}
	nerr := nats.consumer_delete(conn, "HEIM_EVENTS", row.consumer_name)
	if nerr.status != 0 && nerr.jetstream != 10014 do return false, unavailable()
	return false, {}
}
provision_consumer :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	row: domain.Event_Subscription,
) -> (
	bool,
	domain.Domain_Error,
) {
	if !ensure_consumer(s, conn, row) do return false, unavailable()
	return fence_consumer(s, conn, row)
}
Bound_Pull :: struct {
	row:   domain.Event_Subscription, // borrowed from request-owned subscriptions
	pull:  ^nats.Pull,
	slots: int,
}
pull_slots :: proc(s: ^Service, pulls: []Bound_Pull) -> domain.Domain_Error {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return begin_err
	repo := uow.repos.event_subscriptions
	for &bound in pulls {
		slots, err := repo.available(
			repo.ctx,
			bound.row.owner_user_id,
			bound.row.subscriber_agent_id,
			bound.row.subscription_id,
		)
		if err.code != .None {iface.unit_of_work_rollback(&uow); return err}
		bound.slots = slots
	}
	committed, err := iface.unit_of_work_commit(&uow)
	if !committed do return err
	return {}
}
append_unique :: proc(events: ^[dynamic]json.Value, value: json.Value) {
	obj, _ := value.(json.Object)
	id, _ := obj["event_id"].(json.String)
	for prior in events^ {
		prior_obj, _ := prior.(json.Object)
		prior_id, _ := prior_obj["event_id"].(json.String)
		if id == prior_id {json.destroy_value(value); return}
	}
	append(events, value)
}
collect_resolutions :: proc(
	s: ^Service,
	conn: ^nats.Connection,
	owner, agent: string,
	events: ^[dynamic]json.Value,
	limit: int,
) -> domain.Domain_Error {
	rows, err := resolved_snapshot(s, owner, agent, limit - len(events^))
	if err.code != .None do return err
	defer delivery_rows_destroy(rows)
	for row in rows {
		if !row.acknowledged {
			if nats.ack_reply(conn, row.ack_reply, 1000).status != 0 do return unavailable()
			if err = mark(s, owner, agent, row, false); err.code != .None do return err
		}
		data, encode_err := json.marshal(struct {
			type, event_id, resolved_event_id: string,
		}{"resolved", fmt.tprintf("resolved:%s", row.event_id), row.event_id})
		if encode_err != nil do return unavailable()
		notice, parse_err := json.parse(data)
		delete(data)
		if parse_err != nil do return unavailable()
		if err = mark(s, owner, agent, row, true); err.code != .None {json.destroy_value(notice); return err}
		append_unique(events, notice)
		if len(events^) >= limit do break
	}
	return {}
}
// The C batch owns msg. Every success transfers one parsed JSON value; stale
// events are acknowledged and freed while no SQLite transaction is open.
read_message :: proc(
	s: ^Service,
	owner, agent, subscription: string,
	msg: ^nats.Message,
) -> (
	value: json.Value,
	accepted: bool,
	err: domain.Domain_Error,
) {
	parsed, parse_err := json.parse(nats.message_data(msg), parse_integers = true)
	obj, object_ok := parsed.(json.Object)
	id, id_ok := obj["event_id"].(json.String)
	topic, _ := obj["topic_key"].(json.String)
	generation, _ := obj["topic_generation"].(json.Integer)
	if parse_err != nil || !object_ok || !id_ok {
		json.destroy_value(parsed)
		return nil, false, unavailable()
	}
	meta, merr := nats.message_metadata(msg)
	if merr.status != 0 {json.destroy_value(parsed); return nil, false, unavailable()}
	accepted, err = record(
		s,
		owner,
		agent,
		domain.Event_Delivery {
			subscription_id = subscription,
			event_id = string(id),
			ack_reply = nats.message_reply(msg),
			topic_key = string(topic),
			topic_generation = i64(generation),
			stream_sequence = i64(meta.stream_sequence),
		},
	)
	if err.code != .None {json.destroy_value(parsed); return nil, false, err}
	if !accepted {
		json.destroy_value(parsed)
		if nats.ack(msg).status != 0 do return nil, false, unavailable()
		return nil, false, {}
	}
	return parsed, true, {}
}
next :: proc(
	s: ^Service,
	owner, agent: string,
	wait: time.Duration,
	limit: int,
) -> (
	result: []json.Value,
	err: domain.Domain_Error,
) {
	if owner == "" || agent == "" do return nil, domain.domain_error(.Forbidden, "agent identity required")
	if wait < 0 || wait > 30 * time.Second || limit < 1 || limit > 100 do return nil, domain.domain_error(.Validation_Failed, "wait must be 0..30s and limit 1..100")
	events := make([dynamic]json.Value)
	defer if err.code != .None {values_destroy(events[:]); result = nil}
	conn, nerr := nats.connect(s.options)
	if nerr.status != 0 {delete(events); return nil, unavailable()}
	defer nats.destroy(conn)
	if !prepare_advisories(conn) {err = unavailable(); return}
	started := time.tick_now()
	if err = collect_resolutions(s, conn, owner, agent, &events, limit); err.code != .None do return
	if len(events) >= limit do return events[:], {}
	rows, rerr := subscriptions(s, owner, agent)
	if rerr.code != .None {err = rerr; return}
	defer subscription_rows_destroy(rows)
	pulls := make([dynamic]Bound_Pull)
	defer {for bound in pulls do nats.pull_destroy(bound.pull); delete(pulls)}
	// Each durable is provisioned and bound once for this request, with a
	// post-provision fence against lease/watch removal.
	for row in rows {
		live, perr := provision_consumer(s, conn, row)
		if perr.code != .None {err = perr; return}
		if !live do continue
		pull, bind_err := nats.pull_bind(conn, "HEIM_EVENTS", row.consumer_name)
		if bind_err.status != 0 {err = unavailable(); return}
		append(&pulls, Bound_Pull{row = row, pull = pull})
	}
	pass := 0
	for {
		if err = pull_slots(s, pulls[:]); err.code != .None do return
		// First visit every consumer promptly. Then divide the remaining wait
		// among unvisited consumers; idle requests use blocking fetches, not a
		// 20 ms provision/bind/poll loop. Multiple scopes share one wait budget.
		for &bound, i in pulls {
			if bound.slots <= 0 do continue // backpressure; leave backlog in JetStream
			timeout_ms := i64(1)
			if pass > 0 && len(events) == 0 {
				remaining := wait - time.tick_since(started)
				if remaining <= 0 do break
				if remaining < 5 * time.Millisecond {time.sleep(remaining); break}
				timeout_ms = max(1, i64(remaining / time.Duration(len(pulls) - i) / time.Millisecond))
			}
			batch: ^nats.Batch
			berr: nats.Error
			if pass == 0 || len(events) > 0 || timeout_ms < 5 {
				batch, berr = nats.fetch_available(bound.pull, min(limit - len(events), bound.slots))
			} else {
				batch, berr = nats.fetch(bound.pull, min(limit - len(events), bound.slots), timeout_ms)
			}
			if berr.status != 0 {
				nats.batch_destroy(batch)
				if berr.status != 26 {err = unavailable(); return}
				continue
			}
			for i in 0 ..< nats.batch_count(batch) {
				value, accepted, read_err := read_message(
					s,
					owner,
					agent,
					bound.row.subscription_id,
					nats.batch_message(batch, i),
				)
				if read_err.code != .None {nats.batch_destroy(batch); err = read_err; return}
				if accepted do append_unique(&events, value)
			}
			nats.batch_destroy(batch)
			if len(events) >= limit do return events[:], {}
		}
		if err = collect_resolutions(s, conn, owner, agent, &events, limit); err.code != .None do return
		if len(events) > 0 || time.tick_since(started) >= wait do return events[:], {}
		if len(pulls) == 0 {
			time.sleep(max(0, wait - time.tick_since(started)))
			return events[:], {}
		}
		any_slots := false
		for bound in pulls do if bound.slots > 0 do any_slots = true
		if !any_slots {
			// No capacity: do not consume delivery attempts while the agent needs to
			// acknowledge/resolve existing records.
			return events[:], {}
		}
		pass += 1
	}
}
