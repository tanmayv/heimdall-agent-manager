package delivery

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"

try_replace :: proc(s: ^Service, uow: ^iface.Unit_Of_Work, d: domain.Pipeline_Delivery, why: Replace_Why) -> bool {
	if d.round >= domain.DELIVERY_MAX_ROUNDS - 1 do return false
	sink := find_sink(s, d.kind)
	if sink.replace == nil || !sink.replace(sink.ctx, uow, d, why) do return false
	next := d
	next.state = domain.DELIVERY_REPLACED; next.updated_at = platform.clock_now(s.clock)
	repo := &uow.repos.pipeline_deliveries
	changed, err := repo.transition(repo.ctx, next, d.state)
	return changed && err.code == .None
}

on_bridge_online :: proc(s: ^Service, bridge_id: string) {
	b, found, err := iface.bridge_get_bridge(s.bridges, bridge_id)
	if err.code != .None || !found do return
	capable := bridge_capable(b)
	domain.bridge_destroy(&b)
	if !capable {
		bridge_rows(s, bridge_id, .Downgrade)
		disable_forwarder(s, bridge_id)
		return
	}
	bridge_rows(s, bridge_id, .Online)
	sync.mutex_lock(&s.mutex)
	f: ^Forwarder
	for v in s.forwarders do if v.bridge_id == bridge_id {f = v; break}
	if f == nil {
		if len(s.forwarders) >= 256 {
			for id in s.refused_bridges {
				if id == bridge_id {sync.mutex_unlock(&s.mutex); return}
			}
			append(&s.refused_bridges, strings.clone(bridge_id, runtime.heap_allocator()))
			sync.mutex_unlock(&s.mutex)
			sync.atomic_add(&s.forwarders_refused, 1)
			log.warn("delivery forwarder limit reached", bridge_id)
			return
		}
		f = new(Forwarder, runtime.heap_allocator())
		f.service = s; f.bridge_id = strings.clone(bridge_id, runtime.heap_allocator())
		f.answers = make([dynamic]Answer, runtime.heap_allocator())
		append(&s.forwarders, f)
	}
	if s.worker != nil && f.worker == nil {
		context.allocator = runtime.heap_allocator()
		f.worker = thread.create_and_start_with_data(f, forwarder_entry, init_context = context)
	}
	sync.atomic_store(&f.disabled, 0)
	sync.mutex_unlock(&s.mutex)
	sync.sema_post(&f.wake)
}

on_bridge_offline :: proc(s: ^Service, bridge_id: string) {
	bridge_rows(s, bridge_id, .Offline)
}

on_bridge_deleted :: proc(s: ^Service, bridge_id: string) {
	bridge_rows(s, bridge_id, .Deleted)
	disable_forwarder(s, bridge_id)
}

disable_forwarder :: proc(s: ^Service, bridge_id: string) {
	f := find_forwarder(s, bridge_id)
	if f == nil {
		sync.mutex_lock(&s.mutex)
		append(&s.consumer_deletions, strings.clone(bridge_id, runtime.heap_allocator()))
		sync.mutex_unlock(&s.mutex)
		sync.sema_post(&s.wake)
		return
	}
	sync.atomic_store(&f.disabled, 1)
	sync.atomic_store(&f.delete_consumer, 1)
	sync.sema_post(&f.wake)
	sync.sema_post(&s.wake)
}

Bridge_Event :: enum {
	Online,
	Offline,
	Downgrade,
	Deleted,
}
bridge_rows :: proc(s: ^Service, bridge_id: string, event: Bridge_Event) {
	uow, ok, _ := iface.unit_of_work_begin(s.factory)
	if !ok do return
	repo := &uow.repos.pipeline_deliveries
	rows, err := repo.open_for_bridge(repo.ctx, bridge_id, "", -1)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	finalized := false
	for d in rows {
		switch event {
		case .Online:
			if d.expires_at <= platform.clock_now(s.clock) do finalized = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "bridge_offline", "") || finalized
		case .Offline:
			if d.state == domain.DELIVERY_ROUTED do _ = try_replace(s, &uow, d, .Bridge_Offline)
		case .Downgrade:
			if d.state == domain.DELIVERY_ROUTED && try_replace(s, &uow, d, .Downgrade) do continue
			finalized = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "bridge_too_old", "") || finalized
		case .Deleted:
			finalized = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "target_missing", "") || finalized
		}
	}
	domain.pipeline_deliveries_destroy(rows)
	committed, _ := iface.unit_of_work_commit(&uow)
	if committed && finalized do prune_after_final(s)
}
