package eventinbox

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import nats "odin_test:lib/nats"

Notice_Counts :: struct {nudges_sent, wakes_sent: u64}
Counter_Registry :: struct {mutex: sync.Mutex, owners: map[string]Notice_Counts}
// E3 calls this only after successful notice/wake dispatch. Counters are
// process-lifetime, per owner, and contain no content or subscriber identity.
record_notice :: proc(s: ^Service, owner: string, wake: bool) {
	if s == nil || owner == "" do return
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.counters.mutex); defer sync.mutex_unlock(&s.counters.mutex)
	if s.counters.owners == nil do s.counters.owners = make(map[string]Notice_Counts)
	counts, found := s.counters.owners[owner]
	if wake {counts.wakes_sent += 1} else {counts.nudges_sent += 1}
	if found {s.counters.owners[owner] = counts} else {s.counters.owners[strings.clone(owner)] = counts}
}
notice_counts :: proc(s: ^Service, owner: string) -> Notice_Counts {
	sync.mutex_lock(&s.counters.mutex); defer sync.mutex_unlock(&s.counters.mutex)
	return s.counters.owners[owner]
}
counters_destroy :: proc(s: ^Service) {
	context.allocator = runtime.heap_allocator()
	sync.mutex_lock(&s.counters.mutex); defer sync.mutex_unlock(&s.counters.mutex)
	for key in s.counters.owners do delete(key)
	delete(s.counters.owners); s.counters.owners = nil
}
Subscription_Metrics :: struct {subscription_id: string, consumer_lag, ack_pending, redeliveries: u64, available: bool}
Event_Metrics :: struct {
	subscriptions: [dynamic]Subscription_Metrics,
	redeliveries, dlq_count, nudges_sent, wakes_sent: u64,
	outbox_backlog: i64,
}
metrics_destroy :: proc(m: ^Event_Metrics) {
	for row in m.subscriptions do delete(row.subscription_id)
	delete(m.subscriptions); m^ = {}
}
metrics :: proc(s: ^Service, owner: string) -> (result: Event_Metrics, err: domain.Domain_Error) {
	if s == nil || owner == "" || strings.contains_any(owner, ".*> ") do return result, domain.domain_error(.Forbidden, "owner required")
	uow, began, be := iface.unit_of_work_begin(s.factory)
	if !began do return result, be
	repo := uow.repos.event_subscriptions
	rows, re := repo.by_owner(repo.ctx, owner)
	if re.code != .None {iface.unit_of_work_rollback(&uow); return result, re}
	defer subscription_rows_destroy(rows)
	result.outbox_backlog, err = uow.repos.event_outbox.backlog_owner(uow.repos.event_outbox.ctx, owner)
	if err.code != .None {iface.unit_of_work_rollback(&uow); return}
	committed, ce := iface.unit_of_work_commit(&uow)
	if !committed do return result, ce
	counts := notice_counts(s, owner)
	result.nudges_sent = counts.nudges_sent; result.wakes_sent = counts.wakes_sent
	conn, ne := nats.connect(s.options)
	if ne.status != 0 do return result, unavailable()
	defer nats.destroy(conn)
	for row in rows {
		state, ie := nats.consumer_state(conn, "HEIM_EVENTS", row.consumer_name)
		if ie.status != 0 && ie.jetstream != 10014 {metrics_destroy(&result); return result, unavailable()}
		append(&result.subscriptions, Subscription_Metrics{strings.clone(row.subscription_id), state.pending, state.ack_pending, state.redelivered, ie.status == 0})
		result.redeliveries += state.redelivered
	}
	count, de := nats.subject_count(conn, "HEIM_EVENTS", fmt.tprintf("ev.dlq.%s.>", owner))
	if de.status != 0 {metrics_destroy(&result); return result, unavailable()}
	result.dlq_count = count
	return
}
