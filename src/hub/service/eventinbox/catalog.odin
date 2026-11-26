package eventinbox

import "core:encoding/json"
import "core:fmt"
import "core:mem"
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
// The transport owns one connection for its request (or websocket), reusing it
// for all pages. The convenience entry point owns one connection for one page.
catalog_replay :: proc(s: ^Service, owner, chain, cursor: string, limit := 50) -> (page: Catalog_Page, err: domain.Domain_Error) {
	if s == nil do return page, unavailable()
	conn, ne := nats.connect(s.options)
	if ne.status != 0 do return page, unavailable()
	defer nats.destroy(conn)
	return catalog_read(conn, owner, chain, cursor, limit)
}
catalog_read :: proc(conn: ^nats.Connection, owner, chain, cursor: string, limit := 50) -> (page: Catalog_Page, err: domain.Domain_Error) {
	if owner == "" || strings.contains_any(owner, ".*> ") || strings.contains_any(chain, ".*> ") || limit < 1 || limit > 200 do return page, domain.domain_error(.Validation_Failed, "invalid catalog replay")
	after: u64
	if cursor != "" {
		valid: bool
		after, valid = catalog_cursor_parse(cursor)
		if !valid do return page, domain.domain_error(.Validation_Failed, "invalid catalog cursor")
	}
	state, se := nats.stream_info(conn, "HEIM_EVENTS")
	if se.status != 0 do return page, unavailable()
	if cursor == "" {
		page.catalog_cursor = fmt.aprintf("%d", state.last)
		return
	}
	// Cursor names the last scanned sequence, so first-1 is still resumable.
	if after > state.last || state.first > 0 && after < state.first - 1 {
		page.cursor_expired = true
		page.catalog_cursor = fmt.aprintf("%d", state.last)
		return
	}
	prefix := fmt.aprintf("ev.%s.chain.", owner)
	if chain != "" {
		delete(prefix)
		prefix = fmt.aprintf("ev.%s.chain.%s.", owner, chain)
	}
	defer delete(prefix)
	filter := strings.concatenate({prefix, ">"})
	defer delete(filter)
	scanned := 0
	started := time.tick_now()
	for after < state.last && len(page.events) < limit && scanned < 1000 && time.tick_since(started) < 2 * time.Second {
		msg, sequence, ge := nats.stream_next(conn, "HEIM_EVENTS", filter, after + 1)
		if ge.status == 13 {after = state.last; break} // shared NATS_NOT_FOUND contract
		if ge.status != 0 {
			catalog_page_destroy(&page)
			return page, unavailable()
		}
		if msg == nil {after = state.last; break}
		if sequence <= after {nats.message_destroy(msg); catalog_page_destroy(&page); return page, unavailable()}
		// Keep a stable page horizon even if publication continues during replay.
		if sequence > state.last {nats.message_destroy(msg); after = state.last; break}
		after = sequence
		scanned += 1
		if strings.has_prefix(nats.message_subject(msg), prefix) {
			value, decoded := catalog_decode(nats.message_data(msg))
			if decoded {
				obj, object := value.(json.Object)
				tenant, tenant_ok := obj["owner_user_id"].(json.String)
				event_chain := catalog_chain(obj)
                chain_ok := event_chain != ""
				typ, type_ok := obj["type"].(json.String)
				catalog := false
				switch string(typ) {
				case "chain.state", "task.state", "task.review_requested_from_user", "task.blocked_on_human", "task.requirements_changed", "task.review_verdict", "task.merge_conflict", "task.lease_stalled", "chain.work_finished": catalog = true
				}
				if object && tenant_ok && string(tenant) == owner && chain_ok && (chain == "" || string(event_chain) == chain) && type_ok && catalog {
					append(&page.events, value)
				} else {json.destroy_value(value)}
			} else {json.destroy_value(value)}
		}
		nats.message_destroy(msg)
	}
	page.catalog_cursor = fmt.aprintf("%d", after)
	page.has_more = after < state.last
	return
}

// The pinned JSON parser can allocate children before returning a parse error.
// A bounded per-message arena reclaims even unreachable partial values; only
// valid JSON is cloned into the caller's explicitly owned result.
catalog_decode :: proc(data: []byte) -> (json.Value, bool) {
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	value,err:=json.parse(data,parse_integers=true,allocator=mem.dynamic_arena_allocator(&arena))
	defer json.destroy_value(value,allocator=mem.dynamic_arena_allocator(&arena))
	if err!=nil do return nil,false
	return json.clone_value(value),true
}

// Returns the parent chain only for a v2 chain/task entity.
catalog_chain :: proc(obj: json.Object) -> string {
 entity, _ := obj["entity"].(json.Object)
 kind, _ := entity["kind"].(string)
 id, _ := entity["id"].(string)
 if id == "" do return ""
 if kind == "chain" do return id
 if kind == "task" {
  data, _ := obj["data"].(json.Object)
  chain, _ := data["chain_id"].(string)
  return chain
 }
 return ""
}
