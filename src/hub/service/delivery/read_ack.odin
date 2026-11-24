package delivery

import "core:encoding/json"
import "core:fmt"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import nats "odin_test:lib/nats"

// Both definitions and purges travel through the transactional event outbox.
// The multi-token definition subject is outside actions' sched.def.* reconciler.
unread_schedule :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery, purge: bool) -> domain.Domain_Error {
	if !nats.subject_token(d.owner_user_id) || !nats.subject_token(d.delivery_id) do return domain.domain_error(.Validation_Failed, "invalid unread subject")
	now := platform.clock_now(s.clock)
	headers := make(json.Object)
	defer delete(headers)
	if purge {
		headers["Heim-Op"] = string("purge")
	} else {
		ms, ok := platform.rfc3339_to_unix_ms(now)
		if !ok do return domain.domain_error(.Internal_Error, "invalid unread clock")
		at := platform.format_rfc3339_utc(time.Time{_nsec = ms * 1_000_000 + i64(UNREAD_TIMEOUT)})
		headers["Nats-Schedule"] = fmt.tprintf("@at %s", at)
		headers["Nats-Schedule-Target"] = fmt.tprintf("ev.%s.delivery.%s.unread", d.owner_user_id, d.delivery_id)
		headers["Nats-Schedule-TTL"] = string("24h")
	}
	id := platform.generate_id(s.ids, "evt_")
	body, err := json.marshal(struct {
		event_id, type, class, owner_user_id: string,
		data: struct {delivery_id: string},
	}{id, "delivery.unread", "occurrence", d.owner_user_id, {d.delivery_id}})
	if err != nil do return domain.domain_error(.Internal_Error, "cannot encode unread event")
	defer delete(body)
	header_bytes, he := json.marshal(headers)
	if he != nil do return domain.domain_error(.Internal_Error, "cannot encode unread headers")
	defer delete(header_bytes)
	return uow.repos.event_outbox.append(uow.repos.event_outbox.ctx, {
		event_id=id, owner_user_id=d.owner_user_id,
		subject=fmt.tprintf("sched.def.unread.%s", d.delivery_id),
		envelope_json=string(body), headers_json=string(header_bytes), created_at=now,
	})
}

// Content repository rows use request/temporary allocation conventions.
delivery_message :: proc(uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) -> (bool, bool, string, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	m, found, err := iface.content_get_message(&uow.repos.content, d.message_id)
	if !found && err.code == .Not_Found do return false, false, "", {}
	return found && string(m.owner_user_id) == d.owner_user_id, m.read_at != "", m.conversation_id, err
}

prompt_succeeded :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery) -> (bool, bool, domain.Domain_Error) {
	found, read, _, err := delivery_message(uow, d)
	if err.code != .None do return false, false, err
	if !found do return false, false, domain.domain_error(.Internal_Error, "delivery message missing")
	if read {
		changed, e := close_delivery(s, uow, d, domain.DELIVERY_DONE, "", "read")
		return changed, changed, e
	}
	next := d
	next.state = domain.DELIVERY_DELIVERED
	next.outcome = ""; next.reason = ""; next.retry_at = ""
	next.updated_at = platform.clock_now(s.clock)
	ms, valid := platform.rfc3339_to_unix_ms(next.updated_at)
	if !valid do return false, false, domain.domain_error(.Internal_Error, "invalid unread clock")
	// Lazy action lookup expiry recovers a lost or unsupported broker schedule.
	next.expires_at = platform.format_rfc3339_utc(time.Time{_nsec = ms * 1_000_000 + i64(UNREAD_TIMEOUT + UNREAD_EXPIRY_GRACE)})
	changed, e := uow.repos.pipeline_deliveries.transition(uow.repos.pipeline_deliveries.ctx, next, d.state)
	if e.code != .None || !changed do return false, false, e
	if e = unread_schedule(s, uow, next, false); e.code != .None do return false, false, e
	return true, false, {}
}

// Called after read_at is written, within that same unit of work.
on_messages_read :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, owner: domain.User_ID, ids: []string) -> domain.Domain_Error {
	repo := &uow.repos.pipeline_deliveries
	for id in ids {
		rows, err := repo.awaiting_read(repo.ctx, id)
		if err.code != .None do return err
		for d in rows {
			if d.owner_user_id != string(owner) do continue
			_, err = finalize_delivery(s, uow, d, domain.DELIVERY_DONE, "", "read")
			if err.code != .None do break
		}
		domain.pipeline_deliveries_destroy(rows)
		if err.code != .None do return err
	}
	return {}
}

// The existing event matcher invokes this for the NATS scheduled occurrence.
// Commit failure rolls back both the notice route and final state; redelivery
// after success is a no-op, so only one reminder is ever enqueued.
on_unread :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, owner, id: string) -> domain.Domain_Error {
	repo := &uow.repos.pipeline_deliveries
	d, found, err := repo.get(repo.ctx, id)
	defer domain.pipeline_delivery_destroy(&d)
	if err.code != .None do return err
	if !found || d.owner_user_id != owner || d.kind != domain.DELIVERY_KIND_PROMPT || d.state != domain.DELIVERY_DELIVERED do return {}
	exists, read, conversation, me := delivery_message(uow, d)
	if me.code != .None do return me
	if exists && read {
		_, e := finalize_delivery(s, uow, d, domain.DELIVERY_DONE, "", "read")
		return e
	}
	// Reuse notice delivery: it cannot enter another awaiting-read cycle.
	_, re := route(s, uow, {
		kind=domain.DELIVERY_KIND_NOTICE, owner_user_id=owner, bridge_id=d.bridge_id,
		agent_instance_id=d.agent_instance_id, ref=fmt.tprintf("unread:%s", id),
		conversation_id=conversation, message_id=d.message_id,
		cause="unread", notice_line="message", notice_count=1, lifetime=LIFETIME_NOTICE,
	})
	// A deleted or downgraded bridge cannot accept a reminder. It must not
	// keep the original prompt awaiting read forever; storage failures retry.
	if re.code != .None && re.code != .Not_Found && re.code != .Conflict do return re
	_, e := finalize_delivery(s, uow, d, domain.DELIVERY_FAILED, "not_read", "")
	return e
}
