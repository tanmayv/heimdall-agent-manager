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
delivery_snapshot :: proc(
	s: ^Service,
	owner, agent: string,
	include_acknowledged := false,
) -> (
	rows: []domain.Event_Delivery,
	err: domain.Domain_Error,
) {
	uow, began, begin_err := iface.unit_of_work_begin(s.factory)
	if !began do return nil, begin_err
	rows, err = uow.repos.event_subscriptions.deliveries(
		uow.repos.event_subscriptions.ctx,
		owner,
		agent,
		include_acknowledged,
	)
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
	rows, err := delivery_snapshot(s, owner, agent, true)
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
	for {
		// Recheck even acknowledged deliveries: a later resolution must produce a
		// notice without requiring the old message to be redelivered.
		delivered, derr := delivery_snapshot(s, owner, agent)
		if derr.code != .None {err = derr; return}
		for row in delivered {
			if row.topic_key == "" || row.resolved_sent do continue
			stale, serr := is_stale(s, owner, row.topic_key, row.topic_generation)
			if serr.code != .None {delivery_rows_destroy(delivered); err = serr; return}
			if !stale do continue
			if !row.acknowledged {
				if nats.ack_reply(conn, row.ack_reply, 1000).status !=
				   0 {delivery_rows_destroy(delivered); err = unavailable(); return}
				if merr := mark(s, owner, agent, row, false);
				   merr.code != .None {delivery_rows_destroy(delivered); err = merr; return}
			}
			notice_bytes, _ := json.marshal(struct {
				type, event_id, resolved_event_id: string,
			}{"resolved", fmt.tprintf("resolved:%s", row.event_id), row.event_id})
			notice, parse_err := json.parse(notice_bytes)
			delete(notice_bytes)
			if parse_err != nil {delivery_rows_destroy(delivered); err = unavailable(); return}
			if merr := mark(s, owner, agent, row, true);
			   merr.code != .None {json.destroy_value(notice); delivery_rows_destroy(delivered); err = merr; return}
			duplicate := false
			for prior in events {
				prior_obj, _ := prior.(json.Object)
				prior_id, _ := prior_obj["resolved_event_id"].(json.String)
				if string(prior_id) == row.event_id do duplicate = true
			}
			if duplicate {json.destroy_value(notice)} else {append(&events, notice)}
			if len(events) >= limit do break
		}
		delivery_rows_destroy(delivered)
		if len(events) >= limit do return events[:], {}
		rows, rerr := subscriptions(s, owner, agent)
		if rerr.code != .None {err = rerr; return}
		for row in rows {
			if !ensure_consumer(s, conn, row) {subscription_rows_destroy(rows); err = unavailable(); return}
			pull, perr := nats.pull_bind(conn, "HEIM_EVENTS", row.consumer_name)
			if perr.status != 0 {subscription_rows_destroy(rows); err = unavailable(); return}
			batch, berr := nats.fetch(pull, limit - len(events), 20)
			if berr.status != 0 {
				nats.batch_destroy(batch); nats.pull_destroy(pull)
				// NATS_TIMEOUT means a healthy empty consumer; other errors are surfaced.
				if berr.status != 26 {subscription_rows_destroy(rows); err = unavailable(); return}
				continue
			}
			for i in 0 ..< nats.batch_count(batch) {
				msg := nats.batch_message(batch, i)
				value, parse_err := json.parse(nats.message_data(msg), parse_integers = true)
				obj, object_ok := value.(json.Object)
				id, id_ok := obj["event_id"].(json.String)
				topic, _ := obj["topic_key"].(json.String)
				generation, _ := obj["topic_generation"].(json.Integer)
				if parse_err != nil || !object_ok || !id_ok {
					json.destroy_value(value); nats.batch_destroy(batch); nats.pull_destroy(pull)
					subscription_rows_destroy(rows); err = unavailable(); return
				}
				meta, merr := nats.message_metadata(msg)
				record_err: domain.Domain_Error
				accepted := false
				if merr.status == 0 {
					accepted, record_err = record(
						s,
						owner,
						agent,
						domain.Event_Delivery {
							subscription_id = row.subscription_id,
							event_id = string(id),
							ack_reply = nats.message_reply(msg),
							topic_key = string(topic),
							topic_generation = i64(generation),
							stream_sequence = i64(meta.stream_sequence),
						},
					)
				}
				if merr.status != 0 || record_err.code != .None {
					json.destroy_value(value); nats.batch_destroy(batch); nats.pull_destroy(pull)
					subscription_rows_destroy(rows); err = unavailable(); return
				}
				if !accepted {
					json.destroy_value(value)
					if nats.ack(msg).status != 0 {
						nats.batch_destroy(
							batch,
						); nats.pull_destroy(pull); subscription_rows_destroy(rows); err = unavailable(); return
					}
					continue
				}
				// An explicit watch may overlap a coordinator default. Persist both ack
				// replies but return only one copy of an event in the same response.
				duplicate := false
				for prior in events {
					prior_obj, _ := prior.(json.Object)
					prior_id, _ := prior_obj["event_id"].(json.String)
					if prior_id == id do duplicate = true
				}
				if duplicate {json.destroy_value(value)} else {append(&events, value)}
			}
			nats.batch_destroy(batch); nats.pull_destroy(pull)
			if len(events) >= limit do break
		}
		subscription_rows_destroy(rows)
		if len(events) > 0 || time.tick_since(started) >= wait do return events[:], {}
		time.sleep(min(20 * time.Millisecond, wait - time.tick_since(started)))
	}
}
