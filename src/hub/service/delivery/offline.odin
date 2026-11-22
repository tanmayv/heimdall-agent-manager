package delivery

import "base:runtime"
import "core:log"
import "core:strings"
import "core:sync"
import "core:thread"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"

try_replace :: proc(
	s: ^Service,
	uow: ^iface.Unit_Of_Work,
	d: domain.Pipeline_Delivery,
	why: Replace_Why,
) -> (
	bool,
	domain.Domain_Error,
) {
	if d.round >= domain.DELIVERY_MAX_ROUNDS - 1 do return false, {}
	sink := find_sink(s, d.kind)
	if sink.replace == nil do return false, {}
	replaced, err := sink.replace(sink.ctx, uow, d, why)
	if err.code != .None || !replaced do return false, err
	next := d
	next.state = domain.DELIVERY_REPLACED; next.updated_at = platform.clock_now(s.clock)
	repo := &uow.repos.pipeline_deliveries
	changed, transition_err := repo.transition(repo.ctx, next, d.state)
	if transition_err.code != .None do return false, transition_err
	if !changed {
		// The sink already wrote its replacement. The caller must roll back
		// those writes when the original row cannot be replaced atomically.
		return false, domain.domain_error(.Conflict, "delivery replacement lost compare-and-set")
	}
	return true, {}
}

on_bridge_online :: proc(s: ^Service, bridge_id: string) {
	b, found, err := iface.bridge_get_bridge(s.bridges, bridge_id)
	if err.code != .None || !found do return
	capable := bridge_capable(b)
	domain.bridge_destroy(&b)
	if !capable {
		_ = bridge_rows(s, bridge_id, .Downgrade)
		disable_forwarder(s, bridge_id)
		return
	}
	if !bridge_rows(s, bridge_id, .Online) do return
	sync.mutex_lock(&s.mutex)
	f: ^Forwarder
	for v in s.forwarders do if v.bridge_id == bridge_id {f = v; break}
	if f == nil {
		if active_forwarders_locked(s) >= 256 {
			forwarder_refused_locked(s, bridge_id)
			sync.mutex_unlock(&s.mutex)
			return
		}
		f = new(Forwarder, runtime.heap_allocator())
		f.service = s; f.bridge_id = strings.clone(bridge_id, runtime.heap_allocator())
		f.answers = make([dynamic]Answer, runtime.heap_allocator())
		f.disabled = 1
		append(&s.forwarders, f)
	}
	sync.mutex_unlock(&s.mutex)
	sync.mutex_lock(&f.lifecycle)
	sync.mutex_lock(&s.mutex)
	if sync.atomic_load(&f.disabled) != 0 && active_forwarders_locked(s) >= 256 {
		forwarder_refused_locked(s, bridge_id)
		sync.mutex_unlock(&s.mutex)
		sync.mutex_unlock(&f.lifecycle)
		return
	}
	sync.atomic_store(&f.disabled, 0)
	sync.mutex_unlock(&s.mutex)
	if s.worker != nil && f.worker == nil {
		context.allocator = runtime.heap_allocator()
		f.worker = thread.create_and_start_with_data(f, forwarder_entry, init_context = context)
	}
	sync.mutex_unlock(&f.lifecycle)
	sync.sema_post(&f.wake)
}

on_bridge_offline :: proc(s: ^Service, bridge_id: string) {
	_ = bridge_rows(s, bridge_id, .Offline)
}

on_bridge_deleted :: proc(s: ^Service, bridge_id: string) {
	_ = bridge_rows(s, bridge_id, .Deleted)
	disable_forwarder(s, bridge_id)
}

disable_forwarder :: proc(s: ^Service, bridge_id: string) {
	// Serialize retirement against hello/start without holding the map mutex:
	// the supervisor may need the map while a retiring worker leaves conn_lock.
	sync.mutex_lock(&s.mutex)
	f: ^Forwarder
	for v in s.forwarders do if v.bridge_id == bridge_id {f = v; break}
	if f == nil {
		sync.mutex_unlock(&s.mutex)
		queue_consumer_deletion(s, bridge_id)
		return
	}
	sync.mutex_unlock(&s.mutex)
	sync.mutex_lock(&f.lifecycle)
	defer sync.mutex_unlock(&f.lifecycle)
	sync.mutex_lock(&s.mutex)
	sync.atomic_store(&f.disabled, 1)
	sync.mutex_unlock(&s.mutex)
	sync.atomic_store(&f.delete_consumer, 1)
	sync.sema_post(&f.wake)
	sync.sema_post(&s.wake)
	if f.worker != nil {
		thread.join(f.worker)
		thread.destroy(f.worker)
		f.worker = nil
	}
}

Bridge_Event :: enum {
	Online,
	Offline,
	Downgrade,
	Deleted,
}
bridge_rows :: proc(s: ^Service, bridge_id: string, event: Bridge_Event) -> bool {
	uow, ok, _ := iface.unit_of_work_begin(s.factory)
	if !ok do return false
	repo := &uow.repos.pipeline_deliveries
	rows, err := repo.open_for_bridge(repo.ctx, bridge_id, "", -1)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false}
	finalized := false
	for d in rows {
		changed := false
		switch event {
		case .Online:
			if d.expires_at <= platform.clock_now(s.clock) {
				changed, err = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "bridge_offline", "")
				finalized = changed || finalized
			}
		case .Offline:
			if d.state == domain.DELIVERY_ROUTED do changed, err = try_replace(s, &uow, d, .Bridge_Offline)
		case .Downgrade:
			if d.state == domain.DELIVERY_ROUTED do changed, err = try_replace(s, &uow, d, .Downgrade)
			if err.code == .None && !changed {
				changed, err = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "bridge_too_old", "")
				finalized = changed || finalized
			}
		case .Deleted:
			changed, err = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, "target_missing", "")
			finalized = changed || finalized
		}
		if err.code != .None do break
	}
	domain.pipeline_deliveries_destroy(rows)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return false}
	committed, _ := iface.unit_of_work_commit(&uow)
	if committed && finalized do prune_after_final(s)
	return committed
}

// Retired metadata remains stable for concurrent lookups, but consumes no slot.
// Both reservation and retirement update disabled under s.mutex.
active_forwarders_locked :: proc(s: ^Service) -> int {
	count := 0
	for f in s.forwarders do if sync.atomic_load(&f.disabled) == 0 do count += 1
	return count
}

forwarder_refused_locked :: proc(s: ^Service, bridge_id: string) {
	for id in s.refused_bridges do if id == bridge_id do return
	append(&s.refused_bridges, strings.clone(bridge_id, runtime.heap_allocator()))
	sync.atomic_add(&s.forwarders_refused, 1)
	log.warn("delivery forwarder limit reached", bridge_id)
}

queue_consumer_deletion :: proc(s: ^Service, bridge_id: string) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	for id in s.consumer_deletions do if id == bridge_id do return
	append(&s.consumer_deletions, strings.clone(bridge_id, runtime.heap_allocator()))
	sync.sema_post(&s.wake)
}
