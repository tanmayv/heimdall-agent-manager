package delivery

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"
import natstest "odin_test:lib/natstest"

State_Case :: enum {
	Validation,
	Incapable,
	Offline_Route,
	Idempotent,
	Older_Success,
	Final_Retry,
	Fatal,
	Fatal_Replace,
	Offline_Replace,
	Offline_Forwarded,
	Max_Rounds,
	Expired_Online,
	Expired_Start,
	Incapable_Online,
	Deleted,
	Downgrade,
	Queued,
	Prune,
	Prune_Hour,
}

fixture_set :: proc(f: ^Fixture, id, state: string, attempt: int = 1, expires: string = "") {
	uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
	r := &uow.repos.pipeline_deliveries
	d, found, err := r.get(r.ctx, id); assert(found && err.code == .None)
	next := d
	next.state = state; next.attempt = attempt; next.ack_reply = "fake.reply"
	if expires != "" do next.expires_at = expires
	changed, te := r.transition(r.ctx, next, d.state); assert(changed && te.code == .None)
	domain.pipeline_delivery_destroy(&d)
	_, _ = iface.unit_of_work_commit(&uow)
}

state_scenario :: proc(t: ^testing.T, which: State_Case) {
	real_nats := which == .Deleted || which == .Downgrade || which == .Incapable_Online
	f := fixture_new(t, real_nats || which == .Queued)
	defer fixture_destroy(f)
	if which == .Validation || which == .Incapable {
		uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
		defer iface.unit_of_work_rollback(&uow)
		input := Route_Input {
			kind              = "prompt",
			owner_user_id     = "alice",
			bridge_id         = "brg_one",
			agent_instance_id = "inst_one",
			lifetime          = LIFETIME_PROMPT,
		}
		if which == .Incapable {
			f.incapable = 1
			id, err := route(f.s, &uow, input)
			testing.expect(t, id == "" && err.code == .Conflict && err.message == "bridge_too_old")
		} else {
			for i in 0 ..< 5 {
				invalid := input
				switch i {case 0:
					invalid.owner_user_id = "a.b"; case 1:
					invalid.bridge_id = "a.b"; case 2:
					invalid.kind = "unknown"; case 3:
					invalid.lifetime = 0; case 4:
					invalid.round = 3}
				id, err := route(f.s, &uow, invalid)
				testing.expect(t, id == "" && err.code == .Validation_Failed)
			}
		}
		rows, _ := f.repos.pipeline_deliveries.open_for_bridge(f.repos.pipeline_deliveries.ctx, "brg_one", "", -1)
		testing.expect_value(t, len(rows), 0)
		domain.pipeline_deliveries_destroy(rows)
		count, _ := f.repos.event_outbox.backlog(f.repos.event_outbox.ctx)
		testing.expect_value(t, count, i64(0))
		return
	}
	if which == .Incapable_Online {
		testing.expect(t, start(f.s))
		f.incapable = 1; on_bridge_online(f.s, "brg_one")
		testing.expect_value(t, len(f.s.forwarders), 0)
		_, err := nats.consumer_state(f.client, STREAM, "brg_brg_one")
		testing.expect(t, err.status != 0)
		return
	}
	if which == .Prune || which == .Prune_Hour {prune_scenario(t, f, which == .Prune_Hour); return}
	round := 0
	if which == .Max_Rounds do round = 2
	id := fixture_route(t, f, round)
	defer delete(id)
	if which == .Offline_Route {
		d := fixture_get(f, id)
		testing.expect_value(t, d.state, "routed")
		domain.pipeline_delivery_destroy(&d)
		return
	}
	on_bridge_online(f.s, "brg_one") // Creates a queue, without a running worker or NATS.
	if real_nats {
		testing.expect(t, start(f.s))
		fixture_live(f)
		tick := time.tick_now()
		for time.tick_since(tick) < 5 * time.Second {
			_, ce := nats.consumer_state(f.client, STREAM, "brg_brg_one")
			if ce.status == 0 do break
			time.sleep(10 * time.Millisecond)
		}
		_, ce := nats.consumer_state(f.client, STREAM, "brg_brg_one")
		testing.expect_value(t, ce.status, i32(0))
	}
	expected := "done"
	reason := ""
	#partial switch which {
	case .Idempotent, .Older_Success, .Queued:
		fixture_set(f, id, "forwarded", 2)
		if which == .Queued do natstest.stop(&f.server)
		on_command_result(f.s, "other", fmt.tprintf("%s:2", id), `{"status":"succeeded"}`)
		on_command_result(f.s, "brg_one", "dlv_unknown:1", `{"status":"succeeded"}`)
		attempt := 2
		if which == .Older_Success do attempt = 1
		started := time.tick_now()
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:%d", id, attempt), `{"status":"succeeded"}`)
		if which == .Queued do testing.expect(t, time.tick_since(started) < 200 * time.Millisecond, "result callback performs no NATS request")
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:2", id), `{"status":"succeeded"}`)
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:2", id), `{"status":"failed"}`)
		q := take_answers(find_forwarder(f.s, "brg_one"))
		testing.expect_value(t, len(q), 1)
		if len(q) > 0 do testing.expect_value(t, q[0].op, Answer_Op.Ack)
		free_answers(q)
		testing.expect_value(t, sync.atomic_load(&f.finals), i32(1))
	case .Final_Retry, .Fatal, .Fatal_Replace:
		attempt := 1
		if which == .Final_Retry do attempt = f.s.max_deliver
		fixture_set(f, id, "forwarded", attempt)
		f.replace_enabled = which == .Fatal_Replace
		body := `{"payload":{"status":"failed","result":{"class":"fatal"},"error":{"code":"internal_error","cause":"launch_failed"}}}`
		if which == .Final_Retry do body = `{"status":"failed","class":"retry"}`
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:%d", id, attempt), body)
		expected = "failed"; reason = "launch_failed"
		if which == .Final_Retry do reason = "no_answer"
		if which == .Fatal_Replace {expected = "replaced"; reason = ""; assert_replacement(t, f, id)}
	case .Offline_Replace, .Offline_Forwarded, .Max_Rounds:
		f.replace_enabled = true
		if which == .Offline_Forwarded do fixture_set(f, id, "forwarded")
		on_bridge_offline(f.s, "brg_one")
		expected = "routed"
		if which == .Offline_Forwarded do expected = "forwarded"
		if which ==
		   .Offline_Replace {expected = "replaced"; assert_replacement(t, f, id)} else {testing.expect_value(t, sync.atomic_load(&f.replace_calls), i32(0))}
	case .Expired_Online, .Expired_Start:
		fixture_set(f, id, "routed", 0, "2000-01-01T00:00:00Z")
		if which == .Expired_Start {testing.expect(t, start(f.s))} else {on_bridge_online(f.s, "brg_one")}
		expected = "failed"; reason = "bridge_offline"
	case .Deleted:
		on_bridge_deleted(f.s, "brg_one")
		expected = "failed"; reason = "target_missing"
	case .Downgrade:
		f.incapable = 1
		on_bridge_online(f.s, "brg_one")
		expected = "failed"; reason = "bridge_too_old"
	case:
		unreachable()
	}
	d := fixture_get(f, id)
	testing.expect_value(t, d.state, expected)
	testing.expect_value(t, d.reason, reason)
	domain.pipeline_delivery_destroy(&d)
	if real_nats {
		tick := time.tick_now()
		deleted := false
		for time.tick_since(tick) < 5 * time.Second {
			_, ce := nats.consumer_state(f.client, STREAM, "brg_brg_one")
			if ce.jetstream == 10014 {deleted = true; break}
			time.sleep(10 * time.Millisecond)
		}
		testing.expect(t, deleted, "consumer deleted by supervisor")
	}
}

assert_replacement :: proc(t: ^testing.T, f: ^Fixture, old_id: string) {
	uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
	r := &uow.repos.pipeline_deliveries
	d, found, err := r.open_by_ref(r.ctx, "run:one")
	testing.expect(t, found && err.code == .None && d.delivery_id != old_id)
	testing.expect_value(t, d.state, "routed")
	testing.expect_value(t, d.round, 1)
	testing.expect_value(t, d.bridge_id, "brg_two")
	testing.expect(t, strings.contains(d.excluded_bridges_json, "brg_one"))
	domain.pipeline_delivery_destroy(&d)
	iface.unit_of_work_rollback(&uow)
	testing.expect_value(t, sync.atomic_load(&f.finals), i32(0))
}

prune_scenario :: proc(t: ^testing.T, f: ^Fixture, hourly: bool) {
	base, _ := platform.rfc3339_to_unix_ms("2026-11-22T00:00:00Z")
	sync.atomic_store(&f.now_ms, base)
	on_bridge_online(f.s, "brg_one")
	old := fixture_route(t, f)
	defer delete(old)
	uow, ok, _ := iface.unit_of_work_begin(&f.factory); assert(ok)
	r := &uow.repos.pipeline_deliveries
	d, _, _ := r.get(r.ctx, old)
	next := d; next.state = "done"; next.updated_at = "2026-01-01T00:00:00Z"
	changed, err := r.transition(r.ctx, next, d.state)
	testing.expect(t, changed && err.code == .None)
	domain.pipeline_delivery_destroy(&d)
	_, _ = iface.unit_of_work_commit(&uow)
	for _ in 0 ..< (100 if hourly else 1) {
		id := fixture_route(t, f)
		fixture_set(f, id, "forwarded")
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:1", id), `{"status":"succeeded"}`)
		delete(id)
	}
	testing.expect_value(t, sync.atomic_load(&f.s.last_prune_ms), base)
	testing.expect_value(t, sync.atomic_load(&f.s.prune_count), i64(1))
	uow, ok, _ = iface.unit_of_work_begin(&f.factory); assert(ok)
	found: bool
	d, found, _ = r.get(r.ctx, old)
	testing.expect(t, !found, "old closed row pruned")
	domain.pipeline_delivery_destroy(&d)
	iface.unit_of_work_rollback(&uow)
	if hourly {
		sync.atomic_store(&f.now_ms, base + i64(time.Hour / time.Millisecond))
		id := fixture_route(t, f)
		fixture_set(f, id, "forwarded")
		on_command_result(f.s, "brg_one", fmt.tprintf("%s:1", id), `{"status":"succeeded"}`)
		delete(id)
		testing.expect_value(t, sync.atomic_load(&f.s.last_prune_ms), sync.atomic_load(&f.now_ms))
		testing.expect_value(t, sync.atomic_load(&f.s.prune_count), i64(2))
	}
}
