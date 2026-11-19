package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:time"
import "core:strings"
import domain "odin_test:hub/domain"
import nats "odin_test:lib/nats"

Catalog_Page :: struct {
	catalog_cursor: string,
	events: [dynamic]json.Value,
	cursor_expired, has_more: bool,
}
catalog_page_destroy :: proc(p: ^Catalog_Page) {
	delete(p.catalog_cursor)
	for v in p.events do json.destroy_value(v)
	delete(p.events)
	p^ = {}
}
catalog_cursor_parse :: proc(cursor: string) -> (u64, bool) {
	if len(cursor) == 0 || len(cursor) > 20 do return 0, false
	n: u64
	for c in cursor {
		if c < '0' || c > '9' do return 0, false
		digit := u64(c - '0')
		if n > (max(u64) - digit) / 10 do return 0, false
		n = n * 10 + digit
	}
	return n, true
}
// One request owns one connection; all returned JSON and strings are caller-owned.
// Scan work is bounded independently of the result count, including sparse/rolled
// up stream holes. Subject and envelope tenants must both match before returning.
catalog_replay :: proc(s: ^Service, owner, chain, cursor: string, limit := 50) -> (page: Catalog_Page, err: domain.Domain_Error) {
	if s == nil || owner == "" || strings.contains_any(owner, ".*> ") || limit < 1 || limit > 200 do return page, domain.domain_error(.Validation_Failed, "invalid catalog replay")
	after: u64
	if cursor != "" {
		valid: bool
		after, valid = catalog_cursor_parse(cursor)
		if !valid do return page, domain.domain_error(.Validation_Failed, "invalid catalog cursor")
	}
	conn, ne := nats.connect(s.options)
	if ne.status != 0 do return page, unavailable()
	defer nats.destroy(conn)
	state, se := nats.stream_info(conn, "HEIM_EVENTS")
	if se.status != 0 do return page, unavailable()
	if cursor == "" {
		page.catalog_cursor = fmt.aprintf("%d", state.last)
		return
	}
	if after > state.last || state.first > 1 && after < state.first {
		page.cursor_expired = true
		page.catalog_cursor = fmt.aprintf("%d", state.last)
		return
	}
	prefix := fmt.tprintf("ev.%s.chain.", owner)
	if chain != "" do prefix = fmt.tprintf("ev.%s.chain.%s.", owner, chain)
	scanned := 0
	started := time.tick_now()
	for after < state.last && len(page.events) < limit && scanned < 1000 && time.tick_since(started) < 2 * time.Second {
		after += 1
		scanned += 1
		msg, ge := nats.stream_get(conn, "HEIM_EVENTS", after)
		if ge.status != 0 {
			if ge.jetstream == 10037 do continue // rolled-up/expired message
			catalog_page_destroy(&page)
			return page, unavailable()
		}
		if strings.has_prefix(nats.message_subject(msg), prefix) {
			value, pe := json.parse(nats.message_data(msg), parse_integers = true)
			if pe == nil {
				obj, object := value.(json.Object)
				tenant, tenant_ok := obj["owner_user_id"].(json.String)
				event_chain, chain_ok := obj["chain_id"].(json.String)
				typ, type_ok := obj["type"].(json.String)
				catalog := false
				switch string(typ) {
				case "chain.state", "task.state", "task.review_requested_from_user", "task.blocked_on_human", "task.requirements_changed", "task.review_verdict", "task.merge_conflict", "chain.work_finished": catalog = true
				}
				if object && tenant_ok && string(tenant) == owner && chain_ok && (chain == "" || string(event_chain) == chain) && type_ok && catalog {
					append(&page.events, value)
				} else { json.destroy_value(value) }
			}
		}
		nats.message_destroy(msg)
	}
	page.catalog_cursor = fmt.aprintf("%d", after)
	page.has_more = after < state.last
	return
}
