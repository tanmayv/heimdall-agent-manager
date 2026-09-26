package http

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import auth_service "odin_test:hub/service/auth"
import agent_service "odin_test:hub/service/agent"
import content_service "odin_test:hub/service/content"
import project_service "odin_test:hub/service/project"
import taskchain_service "odin_test:hub/service/taskchain"
import events "odin_test:hub/service/events"

Taskchain_Handlers :: struct {
	auth: ^auth_service.Auth_Service,
	taskchains: ^taskchain_service.Taskchain_Service,
	agents: ^agent_service.Agent_Service,
	// content + projects power the project-grouped task-chains list (TC-API): a
	// chain has no project_id column, so its project is resolved via the
	// coordinator instance's conversation (content) and named via the project
	// service. Both may be nil in reduced test wirings; resolution degrades to the
	// "Unassigned" bucket when so.
	content: ^content_service.Content_Service,
	projects: ^project_service.Project_Service,
	event_bus: ^events.User_Event_Bus,
}

// UI-BE-7: publish a lightweight resource_changed event to the owning user's
// live WebSocket clients so the browser can invalidate the smallest relevant
// RTK Query cache and update task/chain views without a manual refresh. These
// are fire-and-forget invalidation hints; the UI refetches authoritative state.
// event_bus may be nil in some test wirings, in which case publish is a no-op.
publish_chain_event :: proc(bus: ^events.User_Event_Bus, owner_user_id, chain_id, change: string) {
	if bus == nil || owner_user_id == "" do return
	summary := taskchain_resource_summary_json("chain_id", chain_id)
	defer delete(summary)
	events.publish_resource_changed(bus, owner_user_id, "task_chain", chain_id, change, summary)
}

publish_task_event :: proc(bus: ^events.User_Event_Bus, owner_user_id, task_id, chain_id, change: string) {
	if bus == nil || owner_user_id == "" do return
	summary := taskchain_task_summary_json(task_id, chain_id)
	defer delete(summary)
	events.publish_resource_changed(bus, owner_user_id, "task", task_id, change, summary)
}

publish_chain_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, chain_id, change: string) {
	if h == nil do return
	publish_chain_event(h.event_bus, owner_user_id, chain_id, change)
}

publish_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, task_id, chain_id, change: string) {
	if h == nil do return
	publish_task_event(h.event_bus, owner_user_id, task_id, chain_id, change)
}

// publish_instance_current_task_changed emits a live event on an agent instance's
// current-task pointer (CT-9) so the dashboard work-vs-review banner updates when
// a coordinator/user switches an agent's focus.
publish_instance_current_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, agent_instance_id, current_task_id, current_task_role: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"agent_instance_id":"`); write_handler_json_string(&b, agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`); write_handler_json_string(&b, current_task_id)
	strings.write_string(&b, `","current_task_role":"`); write_handler_json_string(&b, current_task_role)
	strings.write_string(&b, `"}`)
	events.publish_resource_changed(h.event_bus, owner_user_id, "agent_instance", agent_instance_id, "current_task_changed", strings.to_string(b))
}

taskchain_resource_summary_json :: proc(key, value: string) -> string {
	b := strings.builder_make()
	strings.write_byte(&b, '{')
	strings.write_byte(&b, '"')
	strings.write_string(&b, key)
	strings.write_string(&b, "\":\"")
	write_handler_json_string(&b, value)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

taskchain_task_summary_json :: proc(task_id, chain_id: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"task_id\":\"")
	write_handler_json_string(&b, task_id)
	strings.write_string(&b, "\",\"chain_id\":\"")
	write_handler_json_string(&b, chain_id)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// has_coordinated_by reports whether the query string carries a coordinated_by
// key (even empty), so an instance token can request "chains I coordinate" via
// ?coordinated_by (value defaults to the caller's own instance server-side).
has_coordinated_by :: proc(query: string) -> bool {
	parts := strings.split(query, "&"); defer delete(parts)
	for p in parts {
		if p == "coordinated_by" do return true
		if eq := strings.index_byte(p, '='); eq >= 0 && p[:eq] == "coordinated_by" do return true
	}
	return false
}

list_task_chains_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	// H9 R4: ?coordinated_by=<instance_id> returns the chains that agent instance
	// coordinates (single canonical source). An empty value with an instance token
	// defaults to the caller's own instance. Owner-scoped in the service.
	if has_coordinated_by(req.query) {
		coord_chains, coord_err := taskchain_service.list_chains_coordinated_by(h.taskchains, auth_ctx, query_value(req.query, "coordinated_by"))
		if coord_err.code != .None do return respond_error(coord_err, req.request_id)
		cb := strings.builder_make(); strings.write_byte(&cb, '[')
		for chain, i in coord_chains { if i > 0 do strings.write_byte(&cb, ','); write_chain_json(&cb, chain) }
		strings.write_byte(&cb, ']')
		return respond_list(strings.to_string(cb), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
	}
	include_archived := query_bool(req.query, "include_archived", false) || (has_query_key(req.query, "project_id") && query_value(req.query, "project_id") != "") || (has_query_key(req.query, "status") && query_value(req.query, "status") == "archived")
	if query_bool(req.query, "pinned", false) || query_value(req.query, "pinned") == "1" {
		pinned_chains, pinned_err := taskchain_service.list_pinned_chains(h.taskchains, auth_ctx)
		if pinned_err.code != .None do return respond_error(pinned_err, req.request_id)
		defer delete(pinned_chains)
		items := enrich_chain_list_items(h, auth_ctx, pinned_chains, false, include_archived)
		defer delete(items)
		b := strings.builder_make()
		write_chain_list_items_json(&b, items[:])
		return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
	}
	// Default (no ?coordinated_by): the project-grouped task-chains list (TC-API).
	// Enrich every visible chain with its project (resolved via the coordinator
	// instance's conversation), then either page ONE project or group them ALL.
	chains, err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	// ?has_tasks=1 (or true/yes) hides chains that carry no tasks yet — on real data
	// that is roughly half of them, and an empty chain has nothing to show.
	items := enrich_chain_list_items(h, auth_ctx, chains, query_bool(req.query, "has_tasks", false), include_archived)
	defer delete(items)

	// ?project_id=<id> (value may be empty for the Unassigned bucket) selects the
	// single-project, cursor-paginated view. Its absence returns the grouped view.
	if has_query_key(req.query, "project_id") {
		limit := query_int(req.query, "limit", TASK_CHAINS_PAGE_DEFAULT)
		if limit <= 0 do limit = TASK_CHAINS_PAGE_DEFAULT
		if limit > TASK_CHAINS_PAGE_MAX do limit = TASK_CHAINS_PAGE_MAX
		page := paginate_project_chains(items[:], query_value(req.query, "project_id"), limit, query_value(req.query, "cursor"))
		defer delete(page.chains)
		defer if page.next_cursor != "" do delete(page.next_cursor) // chain_cursor_encode alloc
		b := strings.builder_make()
		write_chain_project_page_json(&b, page)
		return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
	}

	groups := group_chains_by_project(items[:], TASK_CHAINS_GROUP_PREVIEW_CAP)
	defer free_chain_project_groups(groups)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for g, i in groups { if i > 0 do strings.write_byte(&b, ','); write_chain_project_group_json(&b, g) }
	strings.write_byte(&b, ']')
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// TASK_CHAINS_GROUP_PREVIEW_CAP is how many chains the grouped view previews per
// project; TASK_CHAINS_PAGE_DEFAULT/MAX bound the per-project ?limit.
TASK_CHAINS_GROUP_PREVIEW_CAP :: 5
TASK_CHAINS_PAGE_DEFAULT :: 20
TASK_CHAINS_PAGE_MAX :: 100

// has_query_key reports whether the query string carries `key` at all, even with
// an empty value — this distinguishes ?project_id= (the Unassigned bucket) from
// an absent project_id (the grouped view). Mirrors has_coordinated_by.
has_query_key :: proc(query, key: string) -> bool {
	parts := strings.split(query, "&"); defer delete(parts)
	for p in parts {
		if p == key do return true
		if eq := strings.index_byte(p, '='); eq >= 0 && p[:eq] == key do return true
	}
	return false
}

// Chain_List_Item is the flattened, project-enriched chain used by the grouped
// and per-project task-chains views. Its string fields are views into the
// caller-owned chain slice (valid for the request); the JSON serializer copies
// them out. Field set matches the TC-API wire contract exactly.
Chain_List_Item :: struct {
	chain_id:                      string,
	title:                         string,
	status:                        string,
	created_at:                    string,
	updated_at:                    string,
	coordinator_agent_instance_id: string,
	project_id:                    string,
	project_name:                  string,
	task_count:                    int,
	completed_task_count:          int,
	user_validation_count:         int,
	is_pinned:                     bool,
	pinned_at:                     string,
}

// enrich_chain_list_items resolves each chain's project once, memoizing the
// coordinator-instance -> project_id and project_id -> project_name lookups so a
// project shared by many chains costs a single conversation/project fetch. The
// returned dynamic array is caller-owned (delete it); its strings are not.
enrich_chain_list_items :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, chains: []domain.Task_Chain, only_with_tasks: bool, include_archived: bool) -> [dynamic]Chain_List_Item {
	items := make([dynamic]Chain_List_Item)
	proj_idx := conversation_project_index(h, auth)
	defer destroy_conversation_project_index(&proj_idx)
	meta_by_project := make(map[string]Resolved_Project_Meta); defer delete(meta_by_project)
	// One grouped rollup for every chain, not one query per chain.
	task_counts, counts_err := taskchain_service.task_counts_by_chain(h.taskchains, auth)
	defer delete(task_counts)
	// A failed rollup must not silently empty the list: fall back to showing every
	// chain with an unknown (0) count rather than filtering them all away.
	counts_ok := counts_err.code == .None
	for c in chains {
		if !include_archived && c.status == .Archived do continue
		rollup := task_counts[string(c.chain_id)] or_else iface.Chain_Task_Rollup{}
		if only_with_tasks && counts_ok && rollup.total_count == 0 do continue
		coord_id := c.coordinator_agent_instance_id
		if coord_id == "" do coord_id = proj_idx.coord_by_chain[string(c.chain_id)] or_else ""
		project_id := proj_idx.by_instance[c.coordinator_agent_instance_id] or_else ""
		if project_id == "" && string(c.chain_id) in proj_idx.by_chain {
			project_id = proj_idx.by_chain[string(c.chain_id)]
		}
		meta := resolve_project_meta(h, auth, project_id, &meta_by_project)
		if !include_archived && meta.is_archived do continue
		append(&items, Chain_List_Item{
			chain_id = string(c.chain_id),
			title = c.title,
			status = chain_status_http(c.status),
			created_at = c.created_at,
			updated_at = c.updated_at,
			coordinator_agent_instance_id = coord_id,
			project_id = project_id,
			project_name = meta.name,
			task_count = rollup.total_count,
			completed_task_count = rollup.completed_count,
			user_validation_count = rollup.user_validation_count,
			is_pinned = c.is_pinned,
			pinned_at = c.pinned_at,
		})
	}
	return items
}

Conversation_Project_Index :: struct {
	by_instance:    map[string]string,
	by_chain:       map[string]string,
	coord_by_chain: map[string]string,
}

destroy_conversation_project_index :: proc(idx: ^Conversation_Project_Index) {
	delete(idx.by_instance)
	delete(idx.by_chain)
	delete(idx.coord_by_chain)
}

// conversation_project_index maps coordinator instance -> project id AND chain id -> project id
// for the whole request in ONE conversation listing.
//
// This used to be a per-chain lookup (get_conversation_by_instance), memoized by
// coordinator instance. The memo never hit: coordinator instances are unique per
// chain, so an owner with N chains paid N listings — and each listing runs eight
// correlated subqueries per conversation over chat_messages, which has no index on
// conversation_id. Measured on production data (87 chains, 165 conversations, 3491
// messages) that was ~1.4s per listing x 78 coordinators = ~106s, past nginx's 60s
// proxy_read_timeout, so the endpoint 504'd. One listing is one lookup.
//
// Chains with no coordinator, no content service, or no conversation resolve to ""
// and fall into the "Unassigned" bucket.
// NOTE: the listing is bounded (the repository clamps to 200), so an owner with more
// conversations than that would misfile the overflow as "Unassigned" — the same
// bound the old per-chain path had. A by-instance index is the real fix.
conversation_project_index :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context) -> Conversation_Project_Index {
	idx := Conversation_Project_Index{
		by_instance    = make(map[string]string),
		by_chain       = make(map[string]string),
		coord_by_chain = make(map[string]string),
	}
	if h.content == nil do return idx
	rows, err := content_service.list_conversations(h.content, auth, 200, "")
	if err.code != .None do return idx
	defer delete(rows)
	for c in rows {
		if c.agent_instance_id != "" && string(c.project_id) != "" {
			idx.by_instance[c.agent_instance_id] = string(c.project_id)
		}
		if c.chain_id != "" {
			if string(c.project_id) != "" {
				idx.by_chain[c.chain_id] = string(c.project_id)
			}
			if c.agent_instance_id != "" && !(c.chain_id in idx.coord_by_chain) {
				idx.coord_by_chain[c.chain_id] = c.agent_instance_id
			}
		}
	}
	return idx
}

Resolved_Project_Meta :: struct {
	name:        string,
	is_archived: bool,
}

// resolve_project_meta looks up a project's display name and archive status,
// memoized by project id. Empty project id (Unassigned) and unresolved/deleted
// projects return empty name and is_archived = false.
resolve_project_meta :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, project_id: string, cache: ^map[string]Resolved_Project_Meta) -> Resolved_Project_Meta {
	if project_id == "" do return {}
	if cached, ok := cache[project_id]; ok do return cached
	if h.projects == nil do return {}
	p, ok, err := project_service.get(h.projects, auth, domain.Project_ID(project_id))
	// As above: cache a real answer, but not a transient backend error.
	if err.code != .None && err.code != .Not_Found do return {}
	meta := Resolved_Project_Meta{
		name = p.name if ok else "",
		is_archived = ok && p.state == .Archived,
	}
	cache[project_id] = meta
	return meta
}

// chain_list_item_less orders items newest-first by created_at, breaking ties on
// chain_id (descending) so pagination and grouping are deterministic.
chain_list_item_less :: proc(a, b: Chain_List_Item) -> bool {
	if a.created_at != b.created_at do return a.created_at > b.created_at
	return a.chain_id > b.chain_id
}

// chain_cursor_encode / _decode form a COMPOSITE (created_at, chain_id)
// pagination cursor. created_at alone is ambiguous when chains share a timestamp:
// a purely-created_at cursor with a `>=`/`<` filter drops (or repeats) a tied row
// that straddles a page boundary. Carrying chain_id (the sort's tie-breaker) lets
// resumption land strictly AFTER (created_at, chain_id) in the newest-first order,
// so every chain is returned exactly once. Separator mirrors the chat-conversation
// repo's `order|id` cursor convention. Caller owns the returned string.
chain_cursor_encode :: proc(it: Chain_List_Item) -> string {
	return strings.concatenate({it.created_at, "|", it.chain_id})
}
chain_cursor_decode :: proc(cursor: string) -> (created_at: string, chain_id: string) {
	if sep := strings.index_byte(cursor, '|'); sep >= 0 do return cursor[:sep], cursor[sep + 1:]
	return cursor, ""
}
// chain_after_cursor reports whether `it` sorts strictly after the cursor in the
// newest-first (created_at desc, then chain_id desc) order used throughout. An
// empty cursor means "from the start" (include everything).
chain_after_cursor :: proc(it: Chain_List_Item, cur_created_at, cur_chain_id: string) -> bool {
	if cur_created_at == "" do return true
	if it.created_at != cur_created_at do return it.created_at < cur_created_at
	return it.chain_id < cur_chain_id
}

// project_display_name labels the Unassigned bucket; a resolved-but-unnamed
// project (e.g. deleted) keeps its empty name.
project_display_name :: proc(project_id, name: string) -> string {
	if project_id == "" do return "Unassigned"
	return name
}

// Chain_Project_Group is one project's entry in the grouped view: a bounded
// preview of its most-recent chains plus the total/has_more/next_cursor needed to
// page the rest via the per-project view.
Chain_Project_Group :: struct {
	project_id:   string,
	project_name: string,
	chains:       []Chain_List_Item,
	chain_total:  int,
	has_more:     bool,
	next_cursor:  string,
}

// group_chains_by_project groups enriched chains by project, sorts each group's
// chains newest-first, previews up to `preview_cap` per project, and orders the
// groups by their most-recent chain activity. Caller owns the result — free it
// with free_chain_project_groups.
group_chains_by_project :: proc(items: []Chain_List_Item, preview_cap: int) -> []Chain_Project_Group {
	// Collect chains per project, preserving one bucket per distinct project id.
	index_by_project := make(map[string]int); defer delete(index_by_project)
	buckets := make([dynamic][dynamic]Chain_List_Item)
	defer { for &bkt in buckets do delete(bkt); delete(buckets) }
	order := make([dynamic]string); defer delete(order) // project ids, first-seen order
	for it in items {
		idx, seen := index_by_project[it.project_id]
		if !seen {
			idx = len(buckets)
			index_by_project[it.project_id] = idx
			append(&buckets, make([dynamic]Chain_List_Item))
			append(&order, it.project_id)
		}
		append(&buckets[idx], it)
	}

	groups := make([dynamic]Chain_Project_Group)
	for project_id, i in order {
		bucket := buckets[i]
		slice.sort_by(bucket[:], chain_list_item_less)
		total := len(bucket)
		preview_n := total
		if preview_cap >= 0 && preview_n > preview_cap do preview_n = preview_cap
		preview := make([]Chain_List_Item, preview_n)
		for j in 0..<preview_n do preview[j] = bucket[j]
		has_more := total > preview_n
		next_cursor := ""
		// Composite cursor so the client can page the rest of THIS project via the
		// per-project view without losing a chain tied on created_at at the handoff.
		if has_more && preview_n > 0 do next_cursor = chain_cursor_encode(preview[preview_n - 1])
		append(&groups, Chain_Project_Group{
			project_id = project_id,
			project_name = project_display_name(project_id, bucket[0].project_name if total > 0 else ""),
			chains = preview,
			chain_total = total,
			has_more = has_more,
			next_cursor = next_cursor,
		})
	}
	// Order projects by most-recent chain activity (each group's first chain is its
	// newest after the per-group sort); tie-break on project id for determinism.
	slice.sort_by(groups[:], proc(a, b: Chain_Project_Group) -> bool {
		a_at := a.chains[0].updated_at if len(a.chains) > 0 else ""
		b_at := b.chains[0].updated_at if len(b.chains) > 0 else ""
		if a_at != b_at do return a_at > b_at
		return a.project_id < b.project_id
	})
	return groups[:]
}

free_chain_project_groups :: proc(groups: []Chain_Project_Group) {
	for g in groups {
		delete(g.chains)
		if g.next_cursor != "" do delete(g.next_cursor) // chain_cursor_encode alloc
	}
	delete(groups)
}

// Chain_Project_Page is the single-project, cursor-paginated view. chain_total is
// the project's full match count (independent of limit/cursor) — the same figure
// the grouped view carries — so the client's count pill is exact, not per-page.
Chain_Project_Page :: struct {
	project_id:   string,
	project_name: string,
	chains:       []Chain_List_Item,
	chain_total:  int,
	has_more:     bool,
	next_cursor:  string,
}

// paginate_project_chains returns one page of a single project's chains,
// newest-first. `cursor` is a composite (created_at, chain_id) watermark (see
// chain_cursor_encode): only chains that sort strictly after it are returned, so
// chains sharing a created_at across a page boundary are never skipped. The
// returned chains slice and next_cursor are caller-owned (delete them).
paginate_project_chains :: proc(items: []Chain_List_Item, project_id: string, limit: int, cursor: string) -> Chain_Project_Page {
	cur_at, cur_id := chain_cursor_decode(cursor)
	matched := make([dynamic]Chain_List_Item); defer delete(matched)
	project_name := ""
	project_total := 0
	for it in items {
		if it.project_id != project_id do continue
		project_name = it.project_name
		project_total += 1 // full project match count, before the cursor filter
		if !chain_after_cursor(it, cur_at, cur_id) do continue
		append(&matched, it)
	}
	slice.sort_by(matched[:], chain_list_item_less)

	eff_limit := limit
	if eff_limit <= 0 do eff_limit = TASK_CHAINS_PAGE_DEFAULT
	page_n := len(matched)
	if page_n > eff_limit do page_n = eff_limit
	page := make([]Chain_List_Item, page_n)
	for j in 0..<page_n do page[j] = matched[j]
	has_more := len(matched) > page_n
	next_cursor := ""
	if has_more && page_n > 0 do next_cursor = chain_cursor_encode(page[page_n - 1])
	return Chain_Project_Page{
		project_id = project_id,
		project_name = project_display_name(project_id, project_name),
		chains = page,
		chain_total = project_total,
		has_more = has_more,
		next_cursor = next_cursor,
	}
}

// write_chain_list_item_json emits ONE chain in the TC-API wire shape. Field set
// (chain_id,title,status,updated_at,coordinator_agent_instance_id,project_id,
// project_name,task_count) is contractual — keep it in sync with the client.
write_chain_list_item_json :: proc(b: ^strings.Builder, it: Chain_List_Item) {
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, it.chain_id)
	strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, it.title)
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, it.status)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, it.updated_at)
	strings.write_string(b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(b, it.coordinator_agent_instance_id)
	strings.write_string(b, "\",\"project_id\":\""); write_handler_json_string(b, it.project_id)
	strings.write_string(b, "\",\"project_name\":\""); write_handler_json_string(b, it.project_name)
	strings.write_string(b, "\",\"task_count\":"); strings.write_int(b, it.task_count)
	strings.write_string(b, ",\"completed_task_count\":"); strings.write_int(b, it.completed_task_count)
	strings.write_string(b, ",\"user_validation_count\":"); strings.write_int(b, it.user_validation_count)
	strings.write_string(b, ",\"is_pinned\":"); strings.write_string(b, "true" if it.is_pinned else "false")
	strings.write_string(b, ",\"pinned_at\":\""); write_handler_json_string(b, it.pinned_at)
	strings.write_string(b, "\"}")
}

write_chain_list_items_json :: proc(b: ^strings.Builder, items: []Chain_List_Item) {
	strings.write_byte(b, '[')
	for it, i in items { if i > 0 do strings.write_byte(b, ','); write_chain_list_item_json(b, it) }
	strings.write_byte(b, ']')
}

write_chain_project_group_json :: proc(b: ^strings.Builder, g: Chain_Project_Group) {
	strings.write_string(b, "{\"project_id\":\""); write_handler_json_string(b, g.project_id)
	strings.write_string(b, "\",\"project_name\":\""); write_handler_json_string(b, g.project_name)
	strings.write_string(b, "\",\"chains\":"); write_chain_list_items_json(b, g.chains)
	strings.write_string(b, ",\"chain_total\":"); strings.write_int(b, g.chain_total)
	strings.write_string(b, ",\"has_more\":"); strings.write_string(b, "true" if g.has_more else "false")
	strings.write_string(b, ",\"next_cursor\":\""); write_handler_json_string(b, g.next_cursor)
	strings.write_string(b, "\"}")
}

write_chain_project_page_json :: proc(b: ^strings.Builder, p: Chain_Project_Page) {
	strings.write_string(b, "{\"project_id\":\""); write_handler_json_string(b, p.project_id)
	strings.write_string(b, "\",\"project_name\":\""); write_handler_json_string(b, p.project_name)
	strings.write_string(b, "\",\"chains\":"); write_chain_list_items_json(b, p.chains)
	strings.write_string(b, ",\"chain_total\":"); strings.write_int(b, p.chain_total)
	strings.write_string(b, ",\"has_more\":"); strings.write_string(b, "true" if p.has_more else "false")
	strings.write_string(b, ",\"next_cursor\":\""); write_handler_json_string(b, p.next_cursor)
	strings.write_string(b, "\"}")
}

create_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	coord_inst_id := json_string(req.body, "coordinator_agent_instance_id")
	chain, created, err := taskchain_service.create_chain(h.taskchains, auth_ctx, taskchain_service.Create_Chain_Input{
		title = json_string(req.body, "title"),
		description = json_string(req.body, "description"),
		owner_user_id = json_string(req.body, "owner_user_id"),
		kind = json_string(req.body, "kind"),
		coordinator_agent_id = coord_inst_id,
		default_reviewer_refs_json = json_array_raw(req.body, "default_reviewer_refs"),
	})
	if !created do return respond_error(err, req.request_id)
	if coord_agent_id := json_string(req.body, "coordinator_agent_id"); coord_agent_id != "" {
		if h.agents == nil do return respond_error(domain.domain_error(.Internal_Error, "agent service is not configured"), req.request_id)
		inst, inst_created, inst_err := agent_service.create_instance(h.agents, auth_ctx, agent_service.Create_Instance_Input{agent_id = coord_agent_id, bridge_id = json_string(req.body, "bridge_id"), provider = json_string(req.body, "provider"), tier = json_string(req.body, "tier"), project_id = domain.Project_ID(json_string(req.body, "project_id")), chain_id = string(chain.chain_id)})
		if !inst_created do return respond_error(inst_err, req.request_id)
		chain, created, err = taskchain_service.update_chain_coordinator(h.taskchains, auth_ctx, chain.chain_id, inst.agent_instance_id)
		if !created do return respond_error(err, req.request_id)
	}
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "created")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	has_pinned := strings.contains(req.body, "\"is_pinned\"") || strings.contains(req.body, "\"pinned\"")
	is_pinned_val := json_bool(req.body, "is_pinned") if strings.contains(req.body, "\"is_pinned\"") else json_bool(req.body, "pinned")
	chain, updated, err := taskchain_service.update_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), taskchain_service.Update_Chain_Input{
		title = json_string(req.body, "title"),
		description = json_string(req.body, "description"),
		status = json_string(req.body, "status"),
		coordinator_agent_instance_id = json_string(req.body, "coordinator_agent_instance_id"),
		has_coordinator = strings.contains(req.body, "\"coordinator_agent_instance_id\""),
		is_pinned = is_pinned_val,
		has_is_pinned = has_pinned,
	})
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

task_chain_detail_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	// READ (REQ-SEC-3): owner-scoped detail; a same-owner non-member may view it.
	chain, got, err := taskchain_service.get_chain_for_read(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)

	tasks, _ := taskchain_service.list_tasks(h.taskchains, auth_ctx, chain.chain_id)
	members, _ := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain.chain_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain.chain_id)
	dirs, _ := taskchain_service.list_chain_directories(h.taskchains, auth_ctx, chain.chain_id)

	b := strings.builder_make()
	strings.write_string(&b, "{\"chain_id\":\""); write_handler_json_string(&b, string(chain.chain_id))
	strings.write_string(&b, "\",\"title\":\""); write_handler_json_string(&b, chain.title)
	strings.write_string(&b, "\",\"description\":\""); write_handler_json_string(&b, chain.description)
	strings.write_string(&b, "\",\"publish_state\":\""); write_handler_json_string(&b, publish_state_http(chain.publish_state))
	strings.write_string(&b, "\",\"status\":\""); write_handler_json_string(&b, chain_status_http(chain.status))
	strings.write_string(&b, "\",\"kind\":\""); write_handler_json_string(&b, chain.kind)
	strings.write_string(&b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(&b, chain.coordinator_agent_instance_id)
	strings.write_string(&b, "\",\"default_reviewer_refs\":"); strings.write_string(&b, json_or_empty_array(chain.default_reviewer_refs_json))
	strings.write_string(&b, ",\"created_at\":\""); write_handler_json_string(&b, chain.created_at)
	strings.write_string(&b, "\",\"updated_at\":\""); write_handler_json_string(&b, chain.updated_at)
	strings.write_string(&b, "\",\"is_pinned\":"); strings.write_string(&b, "true" if chain.is_pinned else "false")
	strings.write_string(&b, ",\"pinned_at\":\""); write_handler_json_string(&b, chain.pinned_at)
	strings.write_string(&b, "\",\"members\":[")
	for m, i in members {
		if i > 0 do strings.write_byte(&b, ',')
		write_member_json(&b, h, auth_ctx, m)
	}
	strings.write_string(&b, "],\"tasks\":[")
	for task, i in tasks {
		if i > 0 do strings.write_byte(&b, ',')
		write_task_detail_json(&b, h, auth_ctx, task, deps, false)
	}
	strings.write_string(&b, "],\"directories\":[")
	for dir, i in dirs {
		if i > 0 do strings.write_byte(&b, ',')
		write_directory_json(&b, dir)
	}
	strings.write_string(&b, "]}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// reconcile_task_chain_handler runs the explicit self-heal pass on a chain
// (coordinator kickoff + manual re-plan). Coordinator instance token or owner
// only. Returns the number of tasks advanced into In_Progress.
reconcile_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	promoted, done, err := taskchain_service.reconcile_task_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !done do return respond_error(err, req.request_id)
	if chain, cok, _ := taskchain_service.get_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id)); cok {
		publish_chain_changed(h, string(chain.owner_user_id), chain_id, "reconciled")
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\"chain_id\":\""); write_handler_json_string(&b, chain_id)
	strings.write_string(&b, "\",\"reconciled\":true,\"promoted\":"); strings.write_string(&b, fmt.tprintf("%d", promoted))
	strings.write_string(&b, "}")
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

publish_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.publish_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

complete_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	chain, got, err := taskchain_service.change_chain_status(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), .Completed)
	if !got do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

pin_task_chain_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	has_pinned_field := strings.contains(req.body, "\"pinned\"") || strings.contains(req.body, "\"is_pinned\"")
	pinned := true
	if has_pinned_field {
		pinned = json_bool(req.body, "is_pinned") if strings.contains(req.body, "\"is_pinned\"") else json_bool(req.body, "pinned")
	} else {
		cur_chain, cur_ok, cur_err := taskchain_service.get_chain_for_read(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
		if !cur_ok do return respond_error(cur_err, req.request_id)
		pinned = !cur_chain.is_pinned
	}
	chain, updated, err := taskchain_service.pin_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), pinned)
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(chain.owner_user_id), string(chain.chain_id), "updated")
	b := strings.builder_make(); write_chain_json(&b, chain)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_tasks_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	tasks, err := taskchain_service.list_tasks(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if err.code != .None do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	b := strings.builder_make(); strings.write_byte(&b, '[')
	written := 0
	for task in tasks {
		if !task_matches_query(task, req.query) do continue
		if written > 0 do strings.write_byte(&b, ',')
		write_task_detail_json(&b, h, auth_ctx, task, deps, false)
		written += 1
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

// get_task_handler returns ONE task with its comment_summary + votes (slim: no
// comment bodies). Agents/UI fetch the thread separately via .../comments?last=N.
get_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	// READ (REQ-SEC-3): owner-scoped; a same-owner non-member may view the task.
	task, got, err := taskchain_service.get_task_for_read(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain_id)
	b := strings.builder_make()
	write_task_detail_json(&b, h, auth_ctx, task, deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// create_priority_from_body reads an optional "priority" field for a task CREATE.
// Unlike domain.task_priority_from_string — which coerces anything unrecognised to
// P2 — an explicitly present but invalid value is REJECTED here (REQ-CLI-2): a
// create that silently seats "urgent" at p2 is the exact failure this fixes. Absent
// means absent (has = false) and the service applies the documented P2 default.
// Scoped to create on purpose; the update/patch path keeps its existing behaviour.
create_priority_from_body :: proc(body: string) -> (priority: domain.Task_Priority, has: bool, ok: bool, err: domain.Domain_Error) {
	if !strings.contains(body, "\"priority\"") do return .P2, false, true, {}
	raw := strings.trim_space(json_string(body, "priority"))
	switch raw {
	case "p0", "P0": return .P0, true, true, {}
	case "p1", "P1": return .P1, true, true, {}
	case "p2", "P2": return .P2, true, true, {}
	}
	return .P2, false, false, domain.domain_error(.Validation_Failed, "priority must be one of p0, p1, p2")
}

// task_bridge_id_from_body reads the optional "bridge_id" pin for a task CREATE or
// PATCH. Both the cookie API and the agent-action API call it so the two transports
// cannot diverge (same rationale as the shared depends_on parse). `present` is true
// when the key was sent AT ALL — an explicitly empty string is a deliberate clear
// back to inherit on PATCH, while an absent key means inherit on create and "leave
// the pin untouched" on PATCH. The service applies that distinction through
// Create_Task_Input.bridge_id (plain) and the presence-checked
// Update_Task_Input.bridge_id (nil = absent).
task_bridge_id_from_body :: proc(body: string) -> (value: string, present: bool) {
	return json_string(body, "bridge_id"), strings.contains(body, "\"bridge_id\"")
}

create_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	deps := json_array_of_strings(req.body, "depends_on")
	priority, has_priority, prio_ok, prio_err := create_priority_from_body(req.body)
	if !prio_ok do return respond_error(prio_err, req.request_id)
	bridge_id, _ := task_bridge_id_from_body(req.body)
	task, created, err := taskchain_service.create_task(h.taskchains, auth_ctx, taskchain_service.Create_Task_Input{chain_id = domain.Task_Chain_ID(chain_id), title = json_string(req.body, "title"), description = json_string(req.body, "description"), owner_user_id = json_string(req.body, "owner_user_id"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), priority = priority, has_priority = has_priority, depends_on = deps, bridge_id = bridge_id})
	if !created do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "created")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	chain_deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	b := strings.builder_make()
	write_task_detail_json(&b, h, auth_ctx, task, chain_deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	has_deps := strings.contains(req.body, "\"depends_on\"")
	deps := json_array_of_strings(req.body, "depends_on")
	has_priority := strings.contains(req.body, "\"priority\"")
	priority := domain.task_priority_from_string(json_string(req.body, "priority"))
	// bridge_id is presence-checked, not defaulted: absent leaves the pin untouched
	// (nil), present "" clears it back to inherit, and present non-empty repins.
	bridge_id, has_bridge := task_bridge_id_from_body(req.body)
	bridge_pin: ^string
	if has_bridge do bridge_pin = &bridge_id
	task, updated, err := taskchain_service.update_task(h.taskchains, auth_ctx, task_id, taskchain_service.Update_Task_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), priority = priority, has_priority = has_priority, depends_on = deps, has_depends_on = has_deps, bridge_id = bridge_pin})
	if !updated do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

update_task_handler :: patch_task_handler

publish_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, got, err := taskchain_service.publish_task(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

change_task_status_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	status, status_ok := task_status_from_http(json_string(req.body, "status"))
	if !status_ok do return respond_error(domain.domain_error(.Validation_Failed, "invalid task status"), req.request_id)
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, status)
	if !changed do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	// `task` is the RE-READ row (see change_task_status), so its status is what the
	// database holds — which is not always what was asked for: the promotion engine may
	// demote it again in the same request. Pass the requested value so a caller can see
	// both rather than being told its request took effect when it did not.
	b := strings.builder_make(); write_task_json(&b, task, task_status_http(status))
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

cancel_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	task, changed, err := taskchain_service.change_task_status(h.taskchains, auth_ctx, task_id, .Cancelled)
	if !changed do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "status_changed")
	publish_chain_changed(h, string(task.owner_user_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

nudge_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	nudge, nudged, err := taskchain_service.manual_nudge(h.taskchains, auth_ctx, task_id, json_string(req.body, "message"))
	if !nudged do return respond_error(err, req.request_id)
	
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"task_id":"`)
	write_handler_json_string(&b, string(nudge.task_id))
	strings.write_string(&b, `","nudge_id":"`)
	write_handler_json_string(&b, nudge.nudge_id)
	strings.write_string(&b, `","delivery_state":"`)
	write_handler_json_string(&b, nudge.delivery_state)
	strings.write_string(&b, `","live_delivered":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.live_delivered))
	strings.write_string(&b, `,"durable_queued":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.durable_queued))
	strings.write_string(&b, `,"failed":`)
	strings.write_string(&b, fmt.tprintf("%d", nudge.failed))
	strings.write_string(&b, `,"target_role":"`)
	write_handler_json_string(&b, taskchain_service.target_string(nudge.target))
	strings.write_string(&b, `","created_at":"`)
	write_handler_json_string(&b, nudge.created_at)
	strings.write_string(&b, `","targets":`)
	strings.write_string(&b, nudge.targets_json)
	strings.write_string(&b, `}`)
	
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// set_task_current_task_handler lets a coordinator/user pin an agent instance's
// current task to this task (CT-9 manual override). Body: {"agent_instance_id"}.
// The service validates assignee/reviewer eligibility + actionability, persists
// the pointer, and notifies the target agent (work vs review label).
set_task_current_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	instance_id := json_string(req.body, "agent_instance_id")
	if strings.trim_space(instance_id) == "" do return respond_error(domain.domain_error(.Validation_Failed, "agent_instance_id is required"), req.request_id)
	inst, set_ok, err := taskchain_service.set_instance_current_task(h.taskchains, auth_ctx, instance_id, task_id)
	if !set_ok do return respond_error(err, req.request_id)
	publish_task_changed(h, string(inst.owner_user_id), string(task_id), string(chain_id), "current_task_set")
	publish_instance_current_task_changed(h, string(inst.owner_user_id), inst.agent_instance_id, inst.current_task_id, domain.current_task_role_string(inst.current_task_role))
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"agent_instance_id":"`)
	write_handler_json_string(&b, inst.agent_instance_id)
	strings.write_string(&b, `","current_task_id":"`)
	write_handler_json_string(&b, inst.current_task_id)
	strings.write_string(&b, `","current_task_role":"`)
	write_handler_json_string(&b, domain.current_task_role_string(inst.current_task_role))
	strings.write_string(&b, `"}`)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

list_task_comments_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	// ?last=N returns only the newest N comments (bounded); absent/<=0 => all.
	// Cap at TASK_COMMENTS_LAST_MAX so a huge N can't be used to dump everything.
	last := query_int(req.query, "last", 0)
	if last > TASK_COMMENTS_LAST_MAX do last = TASK_COMMENTS_LAST_MAX
	comments, err := taskchain_service.list_recent_task_comments(h.taskchains, auth_ctx, task_id, last)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for c, i in comments { if i > 0 do strings.write_byte(&b, ','); write_task_comment_json(&b, c, resolve_comment_author_display(h, auth_ctx, c)) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

// TASK_COMMENTS_LAST_MAX caps the ?last=N tail fetch so agents can bound payloads
// but can't dump an unbounded thread through the "recent" path.
TASK_COMMENTS_LAST_MAX :: 100

create_task_comment_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	notify := json_array_of_strings_raw(req.body, "notify")
	comment, notified, saved, err := taskchain_service.comment_task(h.taskchains, auth_ctx, taskchain_service.Task_Comment_Input{task_id = task_id, body = json_string(req.body, "body"), notify = notify})
	if !saved do return respond_error(err, req.request_id)
	publish_task_changed(h, string(comment.owner_user_id), string(comment.task_id), string(comment.chain_id), "commented")
	b := strings.builder_make()
	write_task_comment_response_json(&b, comment, resolve_comment_author_display(h, auth_ctx, comment), notified)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

list_task_votes_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	votes, err := taskchain_service.list_task_votes(h.taskchains, auth_ctx, task_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for v, i in votes { if i > 0 do strings.write_byte(&b, ','); write_task_vote_json(&b, v) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

vote_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	task_id := domain.Task_ID(path_part(req.path, 6))
	if matched, mismatch_resp := require_task_path_scope(h, auth_ctx, chain_id, task_id, req); !matched do return mismatch_resp
	vote, recorded, err := taskchain_service.record_task_vote(h.taskchains, auth_ctx, taskchain_service.Vote_Input{task_id = task_id, vote = json_string(req.body, "vote"), comment = json_string(req.body, "comment")})
	if !recorded do return respond_error(err, req.request_id)
	publish_task_changed(h, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "voted")
	publish_chain_changed(h, string(vote.owner_user_id), string(vote.chain_id), "updated")
	if updated_task, task_ok, _ := taskchain_service.get_task(h.taskchains, auth_ctx, vote.task_id); task_ok {
		if updated_task.status == .Completed || updated_task.status == .Validated_Not_Good {
			publish_task_changed(h, string(vote.owner_user_id), string(vote.task_id), string(vote.chain_id), "status_changed")
		}
	}
	b := strings.builder_make(); write_task_vote_json(&b, vote)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

list_chain_members_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	members, err := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make(); strings.write_byte(&b, '[')
	for m, i in members { if i > 0 do strings.write_byte(&b, ','); write_member_json(&b, h, auth_ctx, m) }
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

add_chain_member_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	member, added, err := taskchain_service.add_chain_member(h.taskchains, auth_ctx, chain_id, json_string(req.body, "agent_instance_id"), json_string(req.body, "role"))
	if !added do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(member.owner_user_id), string(member.chain_id), "updated")
	b := strings.builder_make(); write_member_json(&b, h, auth_ctx, member)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

remove_chain_member_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_instance_id := path_part(req.path, 6)
	removed, err := taskchain_service.remove_chain_member(h.taskchains, auth_ctx, chain_id, agent_instance_id)
	if !removed do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

write_directory_json :: proc(b: ^strings.Builder, dir: domain.Task_Chain_Directory) {
	strings.write_string(b, "{\"directory_id\":\""); write_handler_json_string(b, dir.directory_id)
	strings.write_string(b, "\",\"path\":\""); write_handler_json_string(b, dir.path)
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, dir.bridge_id)
	strings.write_string(b, "\",\"vcs_kind\":\""); write_handler_json_string(b, dir.vcs_kind)
	vcs_json := dir.vcs_info_json
	if vcs_json == "" || !strings.starts_with(vcs_json, "{") {
		vcs_json = "{}"
	}
	strings.write_string(b, "\",\"vcs\":")
	strings.write_string(b, vcs_json)
	strings.write_string(b, "}")
}

list_chain_directories_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dirs, err := taskchain_service.list_chain_directories(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for d, i in dirs {
		if i > 0 do strings.write_byte(&b, ',')
		write_directory_json(&b, d)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

add_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	path := json_string(req.body, "path")
	bridge_id := json_string(req.body, "bridge_id")
	vcs_kind := json_string(req.body, "vcs_kind")
	vcs_info_json := "{}"
	if obj, has_obj := json_object_raw_balanced(req.body, "vcs"); has_obj {
		vcs_info_json = obj
	} else if obj2, has_obj2 := json_object_raw_balanced(req.body, "vcs_info"); has_obj2 {
		vcs_info_json = obj2
	} else if s := json_string(req.body, "vcs_info_json"); s != "" {
		vcs_info_json = s
	}
	if vcs_kind == "" {
		if obj_vk := json_string(vcs_info_json, "vcs_kind"); obj_vk != "" {
			vcs_kind = obj_vk
		} else if obj_k := json_string(vcs_info_json, "kind"); obj_k != "" {
			vcs_kind = obj_k
		}
	}
	dir, added, err := taskchain_service.add_chain_directory(h.taskchains, auth_ctx, taskchain_service.Add_Directory_Input{
		chain_id      = chain_id,
		path          = path,
		bridge_id     = bridge_id,
		vcs_kind      = vcs_kind,
		vcs_info_json = vcs_info_json,
	})
	if !added do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(dir.owner_user_id), string(dir.chain_id), "updated")
	b := strings.builder_make()
	write_directory_json(&b, dir)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 201)
}

patch_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	has_path := strings.contains(req.body, "\"path\"")
	has_bridge_id := strings.contains(req.body, "\"bridge_id\"")
	has_vcs_kind := strings.contains(req.body, "\"vcs_kind\"")
	has_vcs_info := strings.contains(req.body, "\"vcs\"") || strings.contains(req.body, "\"vcs_info\"") || strings.contains(req.body, "\"vcs_info_json\"")
	vcs_info_json := "{}"
	if obj, has_obj := json_object_raw_balanced(req.body, "vcs"); has_obj {
		vcs_info_json = obj
	} else if obj2, has_obj2 := json_object_raw_balanced(req.body, "vcs_info"); has_obj2 {
		vcs_info_json = obj2
	} else if s := json_string(req.body, "vcs_info_json"); s != "" {
		vcs_info_json = s
	}
	dir, updated, err := taskchain_service.update_chain_directory(h.taskchains, auth_ctx, taskchain_service.Update_Directory_Input{
		directory_id  = dir_id,
		chain_id      = chain_id,
		path          = json_string(req.body, "path"),
		bridge_id     = json_string(req.body, "bridge_id"),
		vcs_kind      = json_string(req.body, "vcs_kind"),
		vcs_info_json = vcs_info_json,
		has_path      = has_path,
		has_bridge_id = has_bridge_id,
		has_vcs_kind  = has_vcs_kind,
		has_vcs_info  = has_vcs_info,
	})
	if !updated do return respond_error(err, req.request_id)
	publish_chain_changed(h, string(dir.owner_user_id), string(dir.chain_id), "updated")
	b := strings.builder_make()
	write_directory_json(&b, dir)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

remove_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	removed, err := taskchain_service.remove_chain_directory(h.taskchains, auth_ctx, chain_id, dir_id)
	if !removed do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

get_chain_directory_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	dir_id := path_part(req.path, 6)
	dir, found, err := taskchain_service.get_chain_directory(h.taskchains, auth_ctx, chain_id, dir_id)
	if !found do return respond_error(err, req.request_id)
	b := strings.builder_make()
	write_directory_json(&b, dir)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

// Fleet_Restart_Failure is one per-instance relaunch failure reported by the fleet
// upsert when the caller asked to restart live instances. Per-instance failures
// never fail the upsert; they are reported next to the successful restarts.
Fleet_Restart_Failure :: struct {
	instance_id: string,
	message:     string,
}

// The two restart_live_instances bookkeeping params are pointer-optional on purpose:
// the GET list (and any flag-less PUT) passes nil for both, so its payload stays
// byte-identical to the pre-restart contract; the upsert handler passes non-nil
// (possibly empty) values whenever the request carried the flag, and each field is
// emitted only when its pointer is non-nil.
write_fleet_json :: proc(
	b: ^strings.Builder,
	f: domain.Task_Chain_Fleet,
	active_count: int = 0,
	restarted_instance_ids: ^[]string = nil,
	restart_failures: ^[]Fleet_Restart_Failure = nil,
) {
	strings.write_string(b, "{\"task_chain_id\":\"")
	write_handler_json_string(b, string(f.task_chain_id))
	strings.write_string(b, "\",\"agent_id\":\"")
	write_handler_json_string(b, f.agent_id)
	fmt.sbprintf(b, "\",\"capacity\":%d,\"active_count\":%d,\"min_warm\":%d,\"idle_ttl_seconds\":%d,\"created_at\":\"", f.capacity, active_count, f.min_warm, f.idle_ttl_seconds)
	write_handler_json_string(b, f.created_at)
	strings.write_string(b, "\",\"updated_at\":\"")
	write_handler_json_string(b, f.updated_at)
	strings.write_string(b, "\",\"provider\":\"")
	write_handler_json_string(b, f.provider)
	strings.write_string(b, "\",\"tier\":\"")
	write_handler_json_string(b, f.tier)
	strings.write_string(b, "\"")
	if restarted_instance_ids != nil {
		strings.write_string(b, ",\"restarted_instance_ids\":[")
		for instance_id, i in restarted_instance_ids^ {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_byte(b, '"')
			write_handler_json_string(b, instance_id)
			strings.write_byte(b, '"')
		}
		strings.write_byte(b, ']')
	}
	if restart_failures != nil {
		strings.write_string(b, ",\"restart_failures\":[")
		for failure, i in restart_failures^ {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_string(b, "{\"instance_id\":\"")
			write_handler_json_string(b, failure.instance_id)
			strings.write_string(b, "\",\"message\":\"")
			write_handler_json_string(b, failure.message)
			strings.write_string(b, "\"}")
		}
		strings.write_byte(b, ']')
	}
	strings.write_byte(b, '}')
}

json_int_field :: proc(body, key: string, default_value: int) -> int {
	needle := fmt.tprintf("\"%s\"", key)
	idx := strings.index(body, needle)
	if idx < 0 do return default_value
	rest := body[idx + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 do return default_value
	rest = strings.trim_space(rest[colon + 1:])
	if strings.starts_with(rest, "\"") {
		quote_end := strings.index_byte(rest[1:], '"')
		if quote_end < 0 do return default_value
		val_str := rest[1:quote_end + 1]
		if p, ok := strconv.parse_int(val_str); ok do return int(p)
		return default_value
	}
	end := 0
	for end < len(rest) && ((rest[end] >= '0' && rest[end] <= '9') || (end == 0 && rest[end] == '-')) {
		end += 1
	}
	if end == 0 do return default_value
	if p, ok := strconv.parse_int(rest[:end]); ok do return int(p)
	return default_value
}

// fleet_provider_tier_changed reports whether a fleet upsert actually changes the
// role's provider or tier relative to the prior row. Capacity/min_warm/TTL edits
// alone never restart live instances, and a missing prior row has nothing to
// compare against, so both cases report false.
fleet_provider_tier_changed :: proc(prior_provider, prior_tier, provider, tier: string) -> bool {
	return prior_provider != provider || prior_tier != tier
}

// fleet_restart_instance_live mirrors the active_count predicate of the fleet list
// handler: an instance counts as live unless its runtime_status is terminal.
fleet_restart_instance_live :: proc(runtime_status: string) -> bool {
	return runtime_status != "stopped" && runtime_status != "failed" && runtime_status != "terminated"
}

list_chain_fleets_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	fleets, err := taskchain_service.list_fleets(h.taskchains, auth_ctx, chain_id)
	if err.code != .None do return respond_error(err, req.request_id)
	defer delete(fleets)
	members, _ := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
	defer delete(members)
	b := strings.builder_make()
	strings.write_byte(&b, '[')
	for f, i in fleets {
		if i > 0 do strings.write_byte(&b, ',')
		active_count := 0
		for m in members {
			if m.agent_id == f.agent_id {
				if h.agents != nil {
					if inst, inst_ok, _ := agent_service.get_instance(h.agents, auth_ctx, m.agent_instance_id); inst_ok {
						if inst.runtime_status != "stopped" && inst.runtime_status != "failed" && inst.runtime_status != "terminated" {
							active_count += 1
						}
					}
				} else {
					active_count += 1
				}
			}
		}
		write_fleet_json(&b, f, active_count)
	}
	strings.write_byte(&b, ']')
	return respond_list(strings.to_string(b), contracts.API_Page{limit = contracts.API_DEFAULT_PAGE_LIMIT, has_more = false}, req.request_id, auth_ctx_server_time(req))
}

upsert_chain_fleet_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_id := path_part(req.path, 6)
	capacity := json_int_field(req.body, "capacity", 1)
	min_warm := json_int_field(req.body, "min_warm", 0)
	idle_ttl_seconds := json_int_field(req.body, "idle_ttl_seconds", 600)
	provider := json_string(req.body, "provider")
	tier := json_string(req.body, "tier")
	// Optional user-confirmed restart of the role's live instances when this PUT
	// actually changes the role's provider/tier. Absent or malformed values keep the
	// historical flag-less behavior (persist only), so only a well-formed JSON
	// boolean counts as "carried the flag".
	restart_live_instances, restart_flag_ok := json_bool_literal(req.body, "restart_live_instances")
	restart_role_instances := false
	if restart_flag_ok && restart_live_instances {
		role := strings.trim_space(agent_id)
		prior_fleets, prior_err := taskchain_service.list_fleets(h.taskchains, auth_ctx, chain_id)
		defer if prior_err.code == .None do delete(prior_fleets)
		for prior in prior_fleets {
			if prior.agent_id == role {
				restart_role_instances = fleet_provider_tier_changed(prior.provider, prior.tier, provider, tier)
				break
			}
		}
	}
	fleet, err := taskchain_service.upsert_fleet(h.taskchains, auth_ctx, taskchain_service.Upsert_Fleet_Input{
		chain_id         = chain_id,
		agent_id         = agent_id,
		capacity         = capacity,
		min_warm         = min_warm,
		idle_ttl_seconds = idle_ttl_seconds,
		provider         = provider,
		tier             = tier,
	})
	if err.code != .None do return respond_error(err, req.request_id)
	restarted_ids := make([dynamic]string)
	defer delete(restarted_ids)
	restart_failures := make([dynamic]Fleet_Restart_Failure)
	defer delete(restart_failures)
	defer {
		for failure in restart_failures do delete(failure.message)
	}
	if restart_role_instances && h.agents != nil {
		members, members_err := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain_id)
		defer delete(members)
		role := strings.trim_space(agent_id)
		if members_err.code == .None {
			for m in members {
				if m.agent_id != role do continue
				// Unresolvable members (get_instance miss) are skipped silently, and the
				// liveness check matches the fleet list's active_count predicate.
				inst, inst_ok, _ := agent_service.get_instance(h.agents, auth_ctx, m.agent_instance_id)
				if !inst_ok || !fleet_restart_instance_live(inst.runtime_status) do continue
				// relaunch_instance is the primitive that persists the NEW provider/tier
				// verbatim on the same instance id ("" resolves through the standard
				// inheritance order) and re-sends the launch command.
				if _, relaunched, relaunch_err := agent_service.relaunch_instance(h.agents, auth_ctx, inst, provider, tier); relaunched {
					append(&restarted_ids, inst.agent_instance_id)
				} else {
					// Clone: relaunch path messages can come from fmt.tprintf (temp memory).
					append(&restart_failures, Fleet_Restart_Failure{instance_id = inst.agent_instance_id, message = strings.clone(relaunch_err.message)})
				}
			}
		}
	}
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	b := strings.builder_make()
	restarted_out := restarted_ids[:]
	failures_out := restart_failures[:]
	restarted_ptr: ^[]string
	failures_ptr: ^[]Fleet_Restart_Failure
	if restart_flag_ok {
		restarted_ptr = &restarted_out
		failures_ptr = &failures_out
	}
	write_fleet_json(&b, fleet, 0, restarted_ptr, failures_ptr)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req), 200)
}

delete_chain_fleet_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := domain.Task_Chain_ID(path_part(req.path, 4))
	agent_id := path_part(req.path, 6)
	deleted, err := taskchain_service.delete_fleet(h.taskchains, auth_ctx, chain_id, agent_id)
	if !deleted do return respond_error(err, req.request_id)
	publish_chain_changed(h, auth_ctx.user_id, string(chain_id), "updated")
	return respond_success("{\"deleted\":true,\"removed\":true}", req.request_id, auth_ctx_server_time(req))
}

write_chain_json :: proc(b: ^strings.Builder, c: domain.Task_Chain) {
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, c.title); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, c.description); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(c.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, chain_status_http(c.status)); strings.write_string(b, "\",\"kind\":\""); write_handler_json_string(b, c.kind); strings.write_string(b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(b, c.coordinator_agent_instance_id); strings.write_string(b, "\",\"default_reviewer_refs\":"); strings.write_string(b, json_or_empty_array(c.default_reviewer_refs_json)); strings.write_string(b, ",\"created_at\":\""); write_handler_json_string(b, c.created_at); strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, c.updated_at); strings.write_string(b, "\",\"is_pinned\":"); strings.write_string(b, "true" if c.is_pinned else "false"); strings.write_string(b, ",\"pinned_at\":\""); write_handler_json_string(b, c.pinned_at); strings.write_string(b, "\"}")
}

// requested_status is OBSERVATIONAL and optional: pass it only when the caller asked
// for a status the row did not end up holding, and it is emitted alongside the actual
// one so the response cannot imply a change that did not stick. It is a defaulted
// parameter so no existing call site changes, and an additive JSON field so no existing
// consumer breaks. It reports what happened; it never predicts what will happen.
write_task_json :: proc(b: ^strings.Builder, t: domain.Task, requested_status := "") {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id)); strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, t.description); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(t.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status)); strings.write_string(b, "\",\"priority\":\""); write_handler_json_string(b, domain.task_priority_string(t.priority)); strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, t.bridge_id); strings.write_string(b, "\",\"assignee_ref\":"); strings.write_string(b, json_or_empty_object(t.assignee_ref_json)); strings.write_string(b, ",\"reviewer_refs\":"); strings.write_string(b, json_or_empty_array(t.reviewer_refs_json)); strings.write_string(b, ",\"unblocks_dependents\":"); strings.write_string(b, "true" if domain.task_status_unblocks_dependents(t.status) else "false"); strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, t.updated_at); strings.write_string(b, "\"")
	if requested_status != "" && requested_status != task_status_http(t.status) {
		strings.write_string(b, ",\"requested_status\":\""); write_handler_json_string(b, requested_status); strings.write_string(b, "\"")
	}
	strings.write_string(b, "}")
}

write_task_detail_json :: proc(b: ^strings.Builder, h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, t: domain.Task, deps: []domain.Task_Dependency, include_description := true) {
	is_blocked := false
	dep_ids := make([dynamic]string)
	defer delete(dep_ids)
	for d in deps {
		if d.task_id == t.task_id {
			append(&dep_ids, string(d.depends_on_task_id))
			// READ (REQ-SEC-3): rendering helper, owner-scoped dependency lookup.
			if parent, p_ok, _ := taskchain_service.get_task_for_read(h.taskchains, auth_ctx, d.depends_on_task_id); p_ok {
				if !domain.task_status_unblocks_dependents(parent.status) do is_blocked = true
			}
		}
	}

	comment_summary, _ := taskchain_service.task_comment_summary(h.taskchains, auth_ctx, t.task_id)
	votes, _ := taskchain_service.list_task_votes(h.taskchains, auth_ctx, t.task_id)

	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id))
	strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title)
	// Description is fetched lazily (task expand -> single-task GET); the list
	// payload omits it to keep chain/task listings light.
	if include_description {
		strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, t.description)
	}
	strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(t.publish_state))
	strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status))
	strings.write_string(b, "\",\"priority\":\""); write_handler_json_string(b, domain.task_priority_string(t.priority))
	strings.write_string(b, "\",\"bridge_id\":\""); write_handler_json_string(b, t.bridge_id)
	strings.write_string(b, "\",\"assignee_ref\":"); strings.write_string(b, json_or_empty_object(t.assignee_ref_json))
	strings.write_string(b, ",\"reviewer_refs\":"); strings.write_string(b, json_or_empty_array(t.reviewer_refs_json))
	strings.write_string(b, ",\"blocked\":"); strings.write_string(b, "true" if is_blocked else "false")
	strings.write_string(b, ",\"unblocks_dependents\":"); strings.write_string(b, "true" if domain.task_status_unblocks_dependents(t.status) else "false")
	strings.write_string(b, ",\"depends_on\":[")
	for id, i in dep_ids {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "\""); write_handler_json_string(b, id); strings.write_string(b, "\"")
	}
	strings.write_string(b, "],\"comment_summary\":")
	write_task_comment_summary_json(b, comment_summary)
	strings.write_string(b, ",\"votes\":[")
	for v, i in votes {
		if i > 0 do strings.write_byte(b, ',')
		write_task_vote_json(b, v)
	}
	strings.write_string(b, "],\"created_at\":\""); write_handler_json_string(b, t.created_at)
	strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, t.updated_at); strings.write_string(b, "\"}")
}

write_member_json :: proc(b: ^strings.Builder, h: ^Taskchain_Handlers, auth: contracts.Auth_Context, m: domain.Task_Chain_Member) {
	// Enrich each member with the instance's display_name + live runtime/activity
	// status so the client renders member labels + status dots WITHOUT a per-member
	// /agent-instances and /agents fetch. Falls back to the agent name when the
	// instance has no display_name.
	display_name := ""
	runtime_status := ""
	activity_status := ""
	if h != nil && h.agents != nil && strings.trim_space(m.agent_instance_id) != "" {
		if inst, inst_ok, _ := agent_service.get_instance(h.agents, auth, m.agent_instance_id); inst_ok {
			display_name = inst.display_name
			runtime_status = inst.runtime_status
			activity_status = inst.activity_status
		}
		if strings.trim_space(display_name) == "" && strings.trim_space(m.agent_id) != "" {
			if agent, agent_ok, _ := agent_service.get_agent(h.agents, auth, m.agent_id); agent_ok {
				display_name = agent.name
			}
		}
	}
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, string(m.chain_id))
	strings.write_string(b, "\",\"agent_instance_id\":\""); write_handler_json_string(b, m.agent_instance_id)
	strings.write_string(b, "\",\"agent_id\":\""); write_handler_json_string(b, m.agent_id)
	strings.write_string(b, "\",\"role\":\""); write_handler_json_string(b, m.role)
	strings.write_string(b, "\",\"display_name\":\""); write_handler_json_string(b, display_name)
	strings.write_string(b, "\",\"runtime_status\":\""); write_handler_json_string(b, runtime_status)
	strings.write_string(b, "\",\"activity_status\":\""); write_handler_json_string(b, activity_status)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, m.created_at)
	strings.write_string(b, "\"}")
}

// ---- GET /api/v1/agents/live : project -> live-chains -> agents tree ---------
// One call that powers the sidebar rail. It returns EVERY project (alphabetical
// by name, even with nothing live), and a chain is listed under a project when
// the chain has any member (live or dead) in that project AND the chain has >=1
// RUNNING agent somewhere (chains with no running agent are omitted). Per project
// entry: live_agents = that project's running agents (may be empty for a
// dead-only project); members = the full chain roster (live or not). Each agent
// and member carries its own project_id. "live" mirrors the agent-instance live
// filter (agent_service.runtime_expected_active). Field names/casing reuse the
// existing project / chain-member wire contracts.
Agents_Live_Agent :: struct {
	agent_instance_id: string,
	display_name:      string,
	is_coordinator:    bool,
	runtime_status:    string,
	activity_status:   string,
	project_id:        string,
	created_at:        string,
}

Agents_Live_Member :: struct {
	agent_instance_id: string,
	display_name:      string,
	role:              string,
	is_coordinator:    bool,
	is_live:           bool,
	runtime_status:    string,
	project_id:        string,
	created_at:        string,
}

Agents_Live_Chain :: struct {
	chain_id:                      string,
	title:                         string,
	coordinator_agent_instance_id: string,
	live_agents:                   []Agents_Live_Agent,
	members:                       []Agents_Live_Member,
	// group_created_at is the per-project ordering key: MIN(created_at) across this
	// chain's members that belong to THIS project (live AND dead). Not serialized;
	// used only to order chain groups within a project. Empty sorts last.
	group_created_at:              string,
}

Agents_Live_Project :: struct {
	project_id:     string,
	name:           string,
	project_type:   string,
	workspace_name: string,
	chains:         []Agents_Live_Chain,
}

// Deterministic orderings (user-finalized): chain GROUPS within a project by the
// group's earliest member creation time (empty created_at sorts LAST), tie-break
// chain_id; agents/members oldest-first by created_at, tie-break instance id.
agents_live_created_at_less :: proc(a_created, a_id, b_created, b_id: string) -> bool {
	if a_created != b_created {
		// Empty created_at (unknown) sorts after any known timestamp.
		if a_created == "" do return false
		if b_created == "" do return true
		return a_created < b_created
	}
	return a_id < b_id
}
agents_live_chain_less :: proc(a, b: Agents_Live_Chain) -> bool {
	return agents_live_created_at_less(a.group_created_at, a.chain_id, b.group_created_at, b.chain_id)
}
agents_live_agent_less :: proc(a, b: Agents_Live_Agent) -> bool {
	return agents_live_created_at_less(a.created_at, a.agent_instance_id, b.created_at, b.agent_instance_id)
}
agents_live_member_less :: proc(a, b: Agents_Live_Member) -> bool {
	return agents_live_created_at_less(a.created_at, a.agent_instance_id, b.created_at, b.agent_instance_id)
}

// build_agents_live_tree assembles the projects->live-chains->agents tree from
// already-fetched data. It is kept pure (no services) so it is unit-testable
// without a DB. Inputs:
//   projects          all of the owner's projects
//   chains            all of the owner's chains
//   members_by_chain  chain_id -> its canonical member roster (incl. non-live)
//   instances_by_id   agent_instance_id -> instance (liveness + project + labels)
// Cross-project (Option A): a chain is emitted under EVERY project that has >=1
// of its LIVE agents, and under a given project its live_agents are scoped to
// THAT project's live agents only. members[] on every entry is the FULL chain
// roster (all projects, live + non-live), each carrying its own project_id. A
// chain with no live agent anywhere is omitted. Projects are alphabetical by
// name; a trailing "Unassigned" bucket (project_id "") holds live agents whose
// instance has no resolvable project. String fields are VIEWS into the inputs;
// the JSON serializer copies them out. The returned tree is caller-owned — free
// it with free_agents_live_tree.
build_agents_live_tree :: proc(projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) -> []Agents_Live_Project {
	// Per-project buckets of chain entries. Each (chain, project) entry owns fresh
	// live_agents/members slices, so a chain appearing under multiple projects
	// never shares (and thus never double-frees) backing arrays.
	chains_by_project := make(map[string][dynamic]Agents_Live_Chain)
	defer { for _, bkt in chains_by_project do delete(bkt); delete(chains_by_project) }

	for chain in chains {
		members := members_by_chain[string(chain.chain_id)] or_else nil
		// Canonical coordinator (H9): the earliest member with role "coordinator";
		// members come ordered by created_at ASC. Fall back to the derived mirror.
		coordinator_id := chain.coordinator_agent_instance_id
		for m in members {
			if m.role == "coordinator" { coordinator_id = m.agent_instance_id; break }
		}
		// Full roster (members[]), built once and copied into each project entry.
		roster_src := make([dynamic]Agents_Live_Member); defer delete(roster_src)
		// Running agents grouped by their instance.project_id, plus the set of
		// DISTINCT project_ids across ALL members (live+dead) — that set decides which
		// projects the chain is emitted under (placement is member-based, not
		// live-agent-based). has_live gates inclusion: a chain with no running agent
		// anywhere is omitted entirely.
		live_by_project := make(map[string][dynamic]Agents_Live_Agent)
		defer { for _, bkt in live_by_project do delete(bkt); delete(live_by_project) }
		member_project_ids := make(map[string]bool); defer delete(member_project_ids)
		has_live := false
		for m in members {
			inst, has_inst := instances_by_id[m.agent_instance_id]
			live := has_inst && agent_service.runtime_expected_active(inst.runtime_status)
			is_coord := m.agent_instance_id == coordinator_id
			pid := string(inst.project_id) if has_inst else ""
			created_at := inst.created_at if has_inst else ""
			append(&roster_src, Agents_Live_Member{
				agent_instance_id = m.agent_instance_id,
				display_name = inst.display_name if has_inst else "",
				role = m.role,
				is_coordinator = is_coord,
				is_live = live,
				runtime_status = inst.runtime_status if has_inst else "",
				project_id = pid,
				created_at = created_at,
			})
			member_project_ids[pid] = true
			if live {
				has_live = true
				if pid not_in live_by_project do live_by_project[pid] = make([dynamic]Agents_Live_Agent)
				append(&live_by_project[pid], Agents_Live_Agent{
					agent_instance_id = m.agent_instance_id,
					display_name = inst.display_name,
					is_coordinator = is_coord,
					runtime_status = inst.runtime_status,
					activity_status = inst.activity_status,
					project_id = pid,
					created_at = created_at,
				})
			}
		}
		if !has_live do continue // no RUNNING agent anywhere -> omit the chain
		slice.sort_by(roster_src[:], agents_live_member_less)

		// One entry per project that has ANY member (live or dead) of this chain.
		// live_agents is scoped to that project's running agents (may be EMPTY for a
		// dead-only project); members[] is the full (copied) roster. Output order is
		// made deterministic by the project + per-project chain sorts below, so the
		// map iteration order here does not leak.
		for pid in member_project_ids {
			live_dyn, has_here := live_by_project[pid]
			n := len(live_dyn) if has_here else 0
			live_agents := make([]Agents_Live_Agent, n)
			if has_here {
				for a, i in live_dyn do live_agents[i] = a
			}
			slice.sort_by(live_agents, agents_live_agent_less)
			members_copy := make([]Agents_Live_Member, len(roster_src))
			for m, i in roster_src do members_copy[i] = m
			// Group ordering key: earliest created_at among THIS project's members
			// (live or dead). Empty timestamps are ignored unless none are known.
			group_created_at := ""
			for m in roster_src {
				if m.project_id != pid || m.created_at == "" do continue
				if group_created_at == "" || m.created_at < group_created_at do group_created_at = m.created_at
			}
			if pid not_in chains_by_project do chains_by_project[pid] = make([dynamic]Agents_Live_Chain)
			append(&chains_by_project[pid], Agents_Live_Chain{
				chain_id = string(chain.chain_id),
				title = chain.title,
				coordinator_agent_instance_id = coordinator_id,
				live_agents = live_agents,
				members = members_copy,
				group_created_at = group_created_at,
			})
		}
	}

	// Emit ALL projects alphabetically, attaching their live chains; then a
	//    trailing "Unassigned" bucket for live chains with no known project.
	out := make([dynamic]Agents_Live_Project)
	sorted_projects := make([]domain.Project, len(projects)); defer delete(sorted_projects)
	for p, i in projects do sorted_projects[i] = p
	slice.sort_by(sorted_projects, proc(a, b: domain.Project) -> bool {
		if a.name != b.name do return a.name < b.name
		return string(a.project_id) < string(b.project_id)
	})
	matched := make(map[string]bool); defer delete(matched)
	for p in sorted_projects {
		pid := string(p.project_id)
		matched[pid] = true
		bucket := chains_by_project[pid] or_else nil
		if p.state == .Archived {
			for lc in bucket {
				delete(lc.live_agents)
				delete(lc.members)
			}
			continue
		}
		append(&out, Agents_Live_Project{
			project_id = pid,
			name = p.name,
			project_type = p.project_type,
			workspace_name = p.workspace_name,
			chains = agents_live_copy_sorted_chains(bucket[:]),
		})
	}
	unassigned := make([dynamic]Agents_Live_Chain); defer delete(unassigned)
	for pid, bucket in chains_by_project {
		if matched[pid] do continue
		for lc in bucket do append(&unassigned, lc)
	}
	if len(unassigned) > 0 {
		append(&out, Agents_Live_Project{
			project_id = "",
			name = "Unassigned",
			project_type = "local",
			workspace_name = "",
			chains = agents_live_copy_sorted_chains(unassigned[:]),
		})
	}
	return out[:]
}

// agents_live_copy_sorted_chains copies a bucket into a fresh owned slice sorted
// by agents_live_chain_less. The copied structs reference the per-entry
// live_agents/members arrays. Ownership stays single: the builder allocates fresh
// live_agents/members for EACH (chain, project) entry, so even a cross-project
// chain (present in multiple buckets) never shares backing arrays across entries.
agents_live_copy_sorted_chains :: proc(bucket: []Agents_Live_Chain) -> []Agents_Live_Chain {
	out := make([]Agents_Live_Chain, len(bucket))
	for c, i in bucket do out[i] = c
	slice.sort_by(out, agents_live_chain_less)
	return out
}

free_agents_live_tree :: proc(tree: []Agents_Live_Project) {
	for p in tree {
		for c in p.chains {
			delete(c.live_agents)
			delete(c.members)
		}
		delete(p.chains)
	}
	delete(tree)
}

write_agents_live_json :: proc(b: ^strings.Builder, tree: []Agents_Live_Project) {
	strings.write_string(b, "{\"projects\":[")
	for p, pi in tree {
		if pi > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "{\"project_id\":\""); write_handler_json_string(b, p.project_id)
		strings.write_string(b, "\",\"name\":\""); write_handler_json_string(b, p.name)
		strings.write_string(b, "\",\"project_type\":\""); write_handler_json_string(b, p.project_type)
		strings.write_string(b, "\",\"workspace_name\":\""); write_handler_json_string(b, p.workspace_name)
		strings.write_string(b, "\",\"chains\":[")
		for c, ci in p.chains {
			if ci > 0 do strings.write_byte(b, ',')
			strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, c.chain_id)
			strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, c.title)
			strings.write_string(b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(b, c.coordinator_agent_instance_id)
			strings.write_string(b, "\",\"live_agents\":[")
			for a, ai in c.live_agents {
				if ai > 0 do strings.write_byte(b, ',')
				strings.write_string(b, "{\"agent_instance_id\":\""); write_handler_json_string(b, a.agent_instance_id)
				strings.write_string(b, "\",\"display_name\":\""); write_handler_json_string(b, a.display_name)
				strings.write_string(b, "\",\"is_coordinator\":"); strings.write_string(b, "true" if a.is_coordinator else "false")
				strings.write_string(b, ",\"runtime_status\":\""); write_handler_json_string(b, a.runtime_status)
				strings.write_string(b, "\",\"activity_status\":\""); write_handler_json_string(b, a.activity_status)
				strings.write_string(b, "\",\"project_id\":\""); write_handler_json_string(b, a.project_id)
				strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, a.created_at)
				strings.write_string(b, "\"}")
			}
			strings.write_string(b, "],\"members\":[")
			for m, mi in c.members {
				if mi > 0 do strings.write_byte(b, ',')
				strings.write_string(b, "{\"agent_instance_id\":\""); write_handler_json_string(b, m.agent_instance_id)
				strings.write_string(b, "\",\"display_name\":\""); write_handler_json_string(b, m.display_name)
				strings.write_string(b, "\",\"role\":\""); write_handler_json_string(b, m.role)
				strings.write_string(b, "\",\"is_coordinator\":"); strings.write_string(b, "true" if m.is_coordinator else "false")
				strings.write_string(b, ",\"is_live\":"); strings.write_string(b, "true" if m.is_live else "false")
				strings.write_string(b, ",\"runtime_status\":\""); write_handler_json_string(b, m.runtime_status)
				strings.write_string(b, "\",\"project_id\":\""); write_handler_json_string(b, m.project_id)
				strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, m.created_at)
				strings.write_string(b, "\"}")
			}
			strings.write_string(b, "]}")
		}
		strings.write_string(b, "]}")
	}
	strings.write_string(b, "]}")
}

// agents_live_handler serves GET /api/v1/agents/live. It gathers the owner's
// instances (labels + liveness + project in one query), chains, and projects,
// fetches members only for chains that actually have a live instance (bounded),
// then builds + serializes the tree.
agents_live_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	instances, inst_err := agent_service.list_instances(h.agents, auth_ctx, 2000)
	if inst_err.code != .None do return respond_error(inst_err, req.request_id)
	instances_by_id := make(map[string]domain.Agent_Instance); defer delete(instances_by_id)
	live_chain_ids := make(map[string]bool); defer delete(live_chain_ids)
	for inst in instances {
		instances_by_id[inst.agent_instance_id] = inst
		if inst.chain_id != "" && agent_service.runtime_expected_active(inst.runtime_status) do live_chain_ids[inst.chain_id] = true
	}
	chains, chain_err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if chain_err.code != .None do return respond_error(chain_err, req.request_id)
	projects: []domain.Project
	if h.projects != nil {
		ps, perr := project_service.list(h.projects, auth_ctx, 500)
		if perr.code != .None do return respond_error(perr, req.request_id)
		projects = ps
	}
	// Members only for chains with a live instance — the only chains that can be
	// emitted — so we avoid fetching rosters for the (often larger) dormant set.
	members_by_chain := make(map[string][]domain.Task_Chain_Member)
	defer { for _, v in members_by_chain do delete(v); delete(members_by_chain) }
	for chain in chains {
		if !live_chain_ids[string(chain.chain_id)] do continue
		members, merr := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain.chain_id)
		if merr.code != .None do continue
		members_by_chain[string(chain.chain_id)] = members
	}
	tree := build_agents_live_tree(projects, chains, members_by_chain, instances_by_id)
	defer free_agents_live_tree(tree)
	b := strings.builder_make(); write_agents_live_json(&b, tree)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

write_task_vote_json :: proc(b: ^strings.Builder, v: domain.Task_Vote) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(v.task_id))
	strings.write_string(b, "\",\"reviewer_agent_instance_id\":\""); write_handler_json_string(b, v.reviewer_agent_instance_id)
	strings.write_string(b, "\",\"vote\":\""); write_handler_json_string(b, v.vote)
	strings.write_string(b, "\",\"comment\":\""); write_handler_json_string(b, v.comment)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, v.created_at)
	strings.write_string(b, "\"}")
}

// resolve_comment_author_display returns the display name for a comment's author
// agent instance (MEM-7), mirroring write_member_json: prefer the instance's
// display_name, else the durable agent's name. Empty for user-authored comments
// (no author instance) or when it can't be resolved.
resolve_comment_author_display :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, c: domain.Task_Comment) -> string {
	if h == nil || h.agents == nil do return ""
	if strings.trim_space(c.author_agent_instance_id) == "" do return ""
	display_name := ""
	agent_id := ""
	if inst, inst_ok, _ := agent_service.get_instance(h.agents, auth, c.author_agent_instance_id); inst_ok {
		display_name = inst.display_name
		agent_id = inst.agent_id
	}
	if strings.trim_space(display_name) == "" && strings.trim_space(agent_id) != "" {
		if agent, agent_ok, _ := agent_service.get_agent(h.agents, auth, agent_id); agent_ok {
			display_name = agent.name
		}
	}
	return display_name
}

// write_task_comment_json emits a comment. MEM-7: it also carries the resolved
// author_display_name (for a clickable agent label) and author_user_id (the owner
// user id, shown for user-authored comments where author_agent_instance_id is "").
write_task_comment_json :: proc(b: ^strings.Builder, c: domain.Task_Comment, author_display_name: string) {
	strings.write_string(b, "{\"comment_id\":\""); write_handler_json_string(b, c.comment_id)
	strings.write_string(b, "\",\"task_id\":\""); write_handler_json_string(b, string(c.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id))
	strings.write_string(b, "\",\"author_agent_instance_id\":\""); write_handler_json_string(b, c.author_agent_instance_id)
	strings.write_string(b, "\",\"author_display_name\":\""); write_handler_json_string(b, author_display_name)
	strings.write_string(b, "\",\"author_user_id\":\""); write_handler_json_string(b, string(c.owner_user_id))
	strings.write_string(b, "\",\"body\":\""); write_handler_json_string(b, c.body)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\"}")
}

// write_task_comment_summary_json emits the compact comment rollup embedded on
// task objects (count + last comment metadata + preview), replacing the full
// comments array so list/show/context stay cheap.
write_task_comment_summary_json :: proc(b: ^strings.Builder, s: domain.Task_Comment_Summary) {
	strings.write_string(b, "{\"count\":"); strings.write_string(b, fmt.tprintf("%d", s.count))
	strings.write_string(b, ",\"last_comment_at\":\""); write_handler_json_string(b, s.last_comment_at)
	strings.write_string(b, "\",\"last_comment_author_agent_instance_id\":\""); write_handler_json_string(b, s.last_comment_author)
	strings.write_string(b, "\",\"last_comment_preview\":\""); write_handler_json_string(b, s.last_comment_preview)
	strings.write_string(b, "\"}")
}

write_task_comment_response_json :: proc(b: ^strings.Builder, c: domain.Task_Comment, author_display_name: string, notified: []string) {
	strings.write_string(b, "{\"comment_id\":\""); write_handler_json_string(b, c.comment_id)
	strings.write_string(b, "\",\"task_id\":\""); write_handler_json_string(b, string(c.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id))
	strings.write_string(b, "\",\"author_agent_instance_id\":\""); write_handler_json_string(b, c.author_agent_instance_id)
	strings.write_string(b, "\",\"author_display_name\":\""); write_handler_json_string(b, author_display_name)
	strings.write_string(b, "\",\"author_user_id\":\""); write_handler_json_string(b, string(c.owner_user_id))
	strings.write_string(b, "\",\"body\":\""); write_handler_json_string(b, c.body)
	strings.write_string(b, "\",\"created_at\":\""); write_handler_json_string(b, c.created_at)
	strings.write_string(b, "\",\"notified\":[")
	for id, i in notified {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, "\"")
		write_handler_json_string(b, id)
		strings.write_string(b, "\"")
	}
	strings.write_string(b, "]}")
}

json_array_of_strings_raw :: proc(body: string, key: string) -> []string {
	raw := json_array_optional(body, key)
	if raw == "" || raw == "[]" do return nil
	res := make([dynamic]string)
	search := 0
	for search < len(raw) {
		q1 := strings.index_byte(raw[search:], '"')
		if q1 < 0 do break
		q2 := strings.index_byte(raw[search + q1 + 1:], '"')
		if q2 < 0 do break
		val := raw[search + q1 + 1 : search + q1 + 1 + q2]
		if val != "" do append(&res, val)
		search = search + q1 + 1 + q2 + 1
	}
	return res[:]
}

path_part :: proc(path: string, index: int) -> string {
	parts := strings.split(path, "/"); defer delete(parts)
	if index < 0 || index >= len(parts) do return ""
	return parts[index]
}

publish_state_http :: proc(state: domain.Publish_State) -> string { if state == .Published do return "published"; return "draft" }
chain_status_http :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; if status == .Archived do return "archived"; return "active" }
task_status_http :: proc(status: domain.Task_Status) -> string { switch status { case .Assigned: return "assigned"; case .Queued: return "queued"; case .In_Progress: return "in_progress"; case .In_Validation: return "in_validation"; case .Validated_Good: return "validated_good"; case .Validated_Not_Good: return "validated_not_good"; case .Paused: return "paused"; case .Completed: return "completed"; case .Cancelled: return "cancelled" }; return "assigned" }
task_status_from_http :: proc(status: string) -> (domain.Task_Status, bool) { if status == "assigned" do return .Assigned, true; if status == "queued" do return .Queued, true; if status == "in_progress" do return .In_Progress, true; if status == "in_validation" do return .In_Validation, true; if status == "validated_good" do return .Validated_Good, true; if status == "validated_not_good" do return .Validated_Not_Good, true; if status == "paused" do return .Paused, true; if status == "completed" do return .Completed, true; if status == "cancelled" do return .Cancelled, true; return .Assigned, false }


json_or_empty_array :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "[]"; return value }
json_or_empty_object :: proc(value: string) -> string { if strings.trim_space(value) == "" do return "{}"; return value }
json_array_optional :: proc(body, key: string) -> string { start:=json_member_value_start(body,key); if start<0 do return ""; return json_array_from_value(body[start:]) }
json_object_or_empty :: proc(body, key: string) -> string { raw := json_object_raw(body, key); if strings.trim_space(raw) == "" do return ""; return raw }
json_object_raw :: proc(body, key: string) -> string { start:=json_member_value_start(body,key); if start<0 do return ""; return json_object_from_value(body[start:]) }
json_member_value_start :: proc(body,key:string)->int{ i:=0; for i<len(body){ if body[i]!='"' { i+=1; continue }; start:=i+1; j:=start; escaped:=false; for j<len(body){ ch:=body[j]; if escaped { escaped=false; j+=1; continue }; if ch=='\\' { escaped=true; j+=1; continue }; if ch=='"' do break; j+=1 }; if j>=len(body) do return -1; k:=j+1; for k<len(body)&&json_is_ws(body[k]) do k+=1; if body[start:j]==key && k<len(body) && body[k]==':' do return k+1; i=j+1 }; return -1 }
json_array_from_value :: proc(value:string)->string{ i:=0; for i<len(value)&&json_is_ws(value[i]) do i+=1; if i>=len(value)||value[i]!='[' do return "[]"; return json_balanced_from(value[i:], '[', ']') }
json_object_from_value :: proc(value:string)->string{ i:=0; for i<len(value)&&json_is_ws(value[i]) do i+=1; if i>=len(value)||value[i]!='{' do return ""; return json_balanced_from(value[i:], '{', '}') }
json_is_ws :: proc(ch: byte)->bool{ return ch==' ' || ch=='\t' || ch=='\r' || ch=='\n' }
json_balanced_from :: proc(value:string, open, close:byte)->string{ depth:=0; in_string:=false; escaped:=false; for i:=0; i<len(value); i+=1{ ch:=value[i]; if in_string { if escaped { escaped=false; continue }; if ch=='\\' { escaped=true; continue }; if ch=='"' do in_string=false; continue }; if ch=='"' { in_string=true; continue }; if ch==open do depth+=1; if ch==close { depth-=1; if depth==0 do return value[:i+1] } }; return "" }
task_matches_query :: proc(task: domain.Task, query: string) -> bool { assignee:=query_value(query,"assignee_agent_instance_id"); if assignee!="" && !strings.contains(task.assignee_ref_json, assignee) do return false; reviewer:=query_value(query,"reviewer_agent_instance_id"); if reviewer!="" && !strings.contains(task.reviewer_refs_json, reviewer) do return false; reviewer_user:=query_value(query,"reviewer_user_id"); if reviewer_user!="" && !strings.contains(task.reviewer_refs_json, reviewer_user) do return false; return true }

// require_task_path_scope validates that the task exists, is owned by the caller,
// and lives in the chain named in the path. It is a PATH-CONSISTENCY + ownership
// precheck only — it uses the owner-scoped read authorizer (REQ-SEC-3), NOT the
// membership gate, so read handlers work for same-owner non-members. Write
// handlers that call this still enforce membership/coordinator at the service
// layer (create_task/update_task/change_task_status/comment_task/record_task_vote/
// manual_nudge/set_instance_current_task each guard independently).
require_task_path_scope :: proc(h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, req: Request) -> (bool, Response) {
	task, ok, err := taskchain_service.get_task_for_read(h.taskchains, auth_ctx, task_id)
	if !ok do return false, respond_error(err, req.request_id)
	if task.chain_id != chain_id do return false, respond_error(domain.domain_error(.Not_Found, "task not found in chain"), req.request_id)
	return true, Response{}
}

json_array_of_strings :: proc(body: string, key: string) -> []domain.Task_ID {
	raw := json_array_optional(body, key)
	if raw == "" || raw == "[]" do return nil
	res := make([dynamic]domain.Task_ID)
	search := 0
	for search < len(raw) {
		q1 := strings.index_byte(raw[search:], '"')
		if q1 < 0 do break
		q2 := strings.index_byte(raw[search + q1 + 1:], '"')
		if q2 < 0 do break
		val := raw[search + q1 + 1 : search + q1 + 1 + q2]
		if val != "" do append(&res, domain.Task_ID(val))
		search = search + q1 + 1 + q2 + 1
	}
	return res[:]
}
