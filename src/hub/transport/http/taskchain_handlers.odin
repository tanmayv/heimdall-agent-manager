package http

import "core:fmt"
import "core:slice"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
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
publish_chain_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, chain_id, change: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	summary := taskchain_resource_summary_json("chain_id", chain_id)
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, owner_user_id, "task_chain", chain_id, change, summary)
}

publish_task_changed :: proc(h: ^Taskchain_Handlers, owner_user_id, task_id, chain_id, change: string) {
	if h == nil || h.event_bus == nil || owner_user_id == "" do return
	summary := taskchain_task_summary_json(task_id, chain_id)
	defer delete(summary)
	events.publish_resource_changed(h.event_bus, owner_user_id, "task", task_id, change, summary)
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
	// Default (no ?coordinated_by): the project-grouped task-chains list (TC-API).
	// Enrich every visible chain with its project (resolved via the coordinator
	// instance's conversation), then either page ONE project or group them ALL.
	chains, err := taskchain_service.list_chains(h.taskchains, auth_ctx)
	if err.code != .None do return respond_error(err, req.request_id)
	// ?has_tasks=1 (or true/yes) hides chains that carry no tasks yet — on real data
	// that is roughly half of them, and an empty chain has nothing to show.
	items := enrich_chain_list_items(h, auth_ctx, chains, query_bool(req.query, "has_tasks", false))
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
	updated_at:                    string,
	coordinator_agent_instance_id: string,
	project_id:                    string,
	project_name:                  string,
	task_count:                    int,
}

// enrich_chain_list_items resolves each chain's project once, memoizing the
// coordinator-instance -> project_id and project_id -> project_name lookups so a
// project shared by many chains costs a single conversation/project fetch. The
// returned dynamic array is caller-owned (delete it); its strings are not.
enrich_chain_list_items :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, chains: []domain.Task_Chain, only_with_tasks: bool) -> [dynamic]Chain_List_Item {
	items := make([dynamic]Chain_List_Item)
	project_by_instance := conversation_project_index(h, auth); defer delete(project_by_instance)
	name_by_project := make(map[string]string); defer delete(name_by_project)
	// One grouped rollup for every chain, not one query per chain.
	task_counts, counts_err := taskchain_service.task_counts_by_chain(h.taskchains, auth)
	defer delete(task_counts)
	// A failed rollup must not silently empty the list: fall back to showing every
	// chain with an unknown (0) count rather than filtering them all away.
	counts_ok := counts_err.code == .None
	for c in chains {
		count := task_counts[string(c.chain_id)] or_else 0
		if only_with_tasks && counts_ok && count == 0 do continue
		project_id := project_by_instance[c.coordinator_agent_instance_id] or_else ""
		append(&items, Chain_List_Item{
			chain_id = string(c.chain_id),
			title = c.title,
			status = chain_status_http(c.status),
			updated_at = c.updated_at,
			coordinator_agent_instance_id = c.coordinator_agent_instance_id,
			project_id = project_id,
			project_name = resolve_project_name(h, auth, project_id, &name_by_project),
			task_count = count,
		})
	}
	return items
}

// conversation_project_index maps coordinator instance -> project id for the whole
// request in ONE conversation listing.
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
conversation_project_index :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context) -> map[string]string {
	index := make(map[string]string)
	if h.content == nil do return index
	rows, err := content_service.list_conversations(h.content, auth, 200, "")
	if err.code != .None do return index
	defer delete(rows)
	for c in rows {
		if c.agent_instance_id == "" do continue
		index[c.agent_instance_id] = string(c.project_id)
	}
	return index
}

// resolve_project_name looks up a project's display name, memoized by project id.
// Empty project id (Unassigned) and unresolved/deleted projects return "".
resolve_project_name :: proc(h: ^Taskchain_Handlers, auth: contracts.Auth_Context, project_id: string, cache: ^map[string]string) -> string {
	if project_id == "" do return ""
	if cached, ok := cache[project_id]; ok do return cached
	if h.projects == nil do return ""
	p, ok, err := project_service.get(h.projects, auth, domain.Project_ID(project_id))
	// As above: cache a real answer, but not a transient backend error.
	if err.code != .None && err.code != .Not_Found do return ""
	name := p.name if ok else ""
	cache[project_id] = name
	return name
}

// chain_list_item_less orders items newest-first by updated_at, breaking ties on
// chain_id (descending) so pagination and grouping are deterministic.
chain_list_item_less :: proc(a, b: Chain_List_Item) -> bool {
	if a.updated_at != b.updated_at do return a.updated_at > b.updated_at
	return a.chain_id > b.chain_id
}

// chain_cursor_encode / _decode form a COMPOSITE (updated_at, chain_id)
// pagination cursor. updated_at alone is ambiguous when chains share a timestamp:
// a purely-updated_at cursor with a `>=`/`<` filter drops (or repeats) a tied row
// that straddles a page boundary. Carrying chain_id (the sort's tie-breaker) lets
// resumption land strictly AFTER (updated_at, chain_id) in the newest-first order,
// so every chain is returned exactly once. Separator mirrors the chat-conversation
// repo's `order|id` cursor convention. Caller owns the returned string.
chain_cursor_encode :: proc(it: Chain_List_Item) -> string {
	return strings.concatenate({it.updated_at, "|", it.chain_id})
}
chain_cursor_decode :: proc(cursor: string) -> (updated_at: string, chain_id: string) {
	if sep := strings.index_byte(cursor, '|'); sep >= 0 do return cursor[:sep], cursor[sep + 1:]
	return cursor, ""
}
// chain_after_cursor reports whether `it` sorts strictly after the cursor in the
// newest-first (updated_at desc, then chain_id desc) order used throughout. An
// empty cursor means "from the start" (include everything).
chain_after_cursor :: proc(it: Chain_List_Item, cur_updated_at, cur_chain_id: string) -> bool {
	if cur_updated_at == "" do return true
	if it.updated_at != cur_updated_at do return it.updated_at < cur_updated_at
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
		// per-project view without losing a chain tied on updated_at at the handoff.
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
// newest-first. `cursor` is a composite (updated_at, chain_id) watermark (see
// chain_cursor_encode): only chains that sort strictly after it are returned, so
// chains sharing an updated_at across a page boundary are never skipped. The
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
	strings.write_byte(b, '}')
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
	chain, created, err := taskchain_service.create_chain(h.taskchains, auth_ctx, taskchain_service.Create_Chain_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), owner_user_id = json_string(req.body, "owner_user_id"), kind = json_string(req.body, "kind"), coordinator_agent_id = json_string(req.body, "coordinator_agent_id"), default_reviewer_refs_json = json_array_raw(req.body, "default_reviewer_refs")})
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
	chain, updated, err := taskchain_service.update_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id), taskchain_service.Update_Chain_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), status = json_string(req.body, "status"), coordinator_agent_instance_id = json_string(req.body, "coordinator_agent_instance_id"), has_coordinator = strings.contains(req.body, "\"coordinator_agent_instance_id\"")})
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
	chain, got, err := taskchain_service.get_chain(h.taskchains, auth_ctx, domain.Task_Chain_ID(chain_id))
	if !got do return respond_error(err, req.request_id)

	tasks, _ := taskchain_service.list_tasks(h.taskchains, auth_ctx, chain.chain_id)
	members, _ := taskchain_service.list_chain_members(h.taskchains, auth_ctx, chain.chain_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain.chain_id)

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
	task, got, err := taskchain_service.get_task(h.taskchains, auth_ctx, task_id)
	if !got do return respond_error(err, req.request_id)
	deps, _ := taskchain_service.list_chain_dependencies(h.taskchains, auth_ctx, chain_id)
	b := strings.builder_make()
	write_task_detail_json(&b, h, auth_ctx, task, deps)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

create_task_handler :: proc(ctx: rawptr, req: Request) -> Response {
	h := (^Taskchain_Handlers)(ctx)
	auth_ctx, ok, auth_resp := require_auth_any(h.auth, req)
	if !ok do return auth_resp
	chain_id := path_part(req.path, 4)
	deps := json_array_of_strings(req.body, "depends_on")
	task, created, err := taskchain_service.create_task(h.taskchains, auth_ctx, taskchain_service.Create_Task_Input{chain_id = domain.Task_Chain_ID(chain_id), title = json_string(req.body, "title"), description = json_string(req.body, "description"), owner_user_id = json_string(req.body, "owner_user_id"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), depends_on = deps})
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
	task, updated, err := taskchain_service.update_task(h.taskchains, auth_ctx, task_id, taskchain_service.Update_Task_Input{title = json_string(req.body, "title"), description = json_string(req.body, "description"), assignee_ref_json = json_object_or_empty(req.body, "assignee_ref"), reviewer_refs_json = json_array_optional(req.body, "reviewer_refs"), priority = priority, has_priority = has_priority, depends_on = deps, has_depends_on = has_deps})
	if !updated do return respond_error(err, req.request_id)
	publish_task_changed(h, string(task.owner_user_id), string(task.task_id), string(task.chain_id), "updated")
	b := strings.builder_make(); write_task_json(&b, task)
	return respond_success(strings.to_string(b), req.request_id, auth_ctx_server_time(req))
}

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
	b := strings.builder_make(); write_task_json(&b, task)
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
	for c, i in comments { if i > 0 do strings.write_byte(&b, ','); write_task_comment_json(&b, c) }
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
	write_task_comment_response_json(&b, comment, notified)
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

write_chain_json :: proc(b: ^strings.Builder, c: domain.Task_Chain) {
	strings.write_string(b, "{\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, c.title); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, c.description); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(c.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, chain_status_http(c.status)); strings.write_string(b, "\",\"kind\":\""); write_handler_json_string(b, c.kind); strings.write_string(b, "\",\"coordinator_agent_instance_id\":\""); write_handler_json_string(b, c.coordinator_agent_instance_id); strings.write_string(b, "\",\"default_reviewer_refs\":"); strings.write_string(b, json_or_empty_array(c.default_reviewer_refs_json)); strings.write_string(b, ",\"created_at\":\""); write_handler_json_string(b, c.created_at); strings.write_string(b, "\",\"updated_at\":\""); write_handler_json_string(b, c.updated_at); strings.write_string(b, "\"}")
}

write_task_json :: proc(b: ^strings.Builder, t: domain.Task) {
	strings.write_string(b, "{\"task_id\":\""); write_handler_json_string(b, string(t.task_id)); strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(t.chain_id)); strings.write_string(b, "\",\"title\":\""); write_handler_json_string(b, t.title); strings.write_string(b, "\",\"description\":\""); write_handler_json_string(b, t.description); strings.write_string(b, "\",\"publish_state\":\""); write_handler_json_string(b, publish_state_http(t.publish_state)); strings.write_string(b, "\",\"status\":\""); write_handler_json_string(b, task_status_http(t.status)); strings.write_string(b, "\",\"priority\":\""); write_handler_json_string(b, domain.task_priority_string(t.priority)); strings.write_string(b, "\",\"assignee_ref\":"); strings.write_string(b, json_or_empty_object(t.assignee_ref_json)); strings.write_string(b, ",\"reviewer_refs\":"); strings.write_string(b, json_or_empty_array(t.reviewer_refs_json)); strings.write_string(b, ",\"unblocks_dependents\":"); strings.write_string(b, "true" if domain.task_status_unblocks_dependents(t.status) else "false"); strings.write_string(b, ",\"updated_at\":\""); write_handler_json_string(b, t.updated_at); strings.write_string(b, "\"}")
}

write_task_detail_json :: proc(b: ^strings.Builder, h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, t: domain.Task, deps: []domain.Task_Dependency, include_description := true) {
	is_blocked := false
	dep_ids := make([dynamic]string)
	defer delete(dep_ids)
	for d in deps {
		if d.task_id == t.task_id {
			append(&dep_ids, string(d.depends_on_task_id))
			if parent, p_ok, _ := taskchain_service.get_task(h.taskchains, auth_ctx, d.depends_on_task_id); p_ok {
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
// by name, even with nothing live) -> the task-chains in that project that
// currently have >=1 LIVE agent (chains with no live agent are omitted) -> those
// chains' live agents plus the full member roster (live or not). "live" mirrors
// the agent-instance live filter (agent_service.runtime_expected_active). Field
// names/casing reuse the existing project / chain-member wire contracts.
Agents_Live_Agent :: struct {
	agent_instance_id: string,
	display_name:      string,
	is_coordinator:    bool,
	runtime_status:    string,
	activity_status:   string,
}

Agents_Live_Member :: struct {
	agent_instance_id: string,
	display_name:      string,
	role:              string,
	is_coordinator:    bool,
	is_live:           bool,
	runtime_status:    string,
}

Agents_Live_Chain :: struct {
	chain_id:                      string,
	title:                         string,
	coordinator_agent_instance_id: string,
	live_agents:                   []Agents_Live_Agent,
	members:                       []Agents_Live_Member,
}

Agents_Live_Project :: struct {
	project_id: string,
	name:       string,
	chains:     []Agents_Live_Chain,
}

// Deterministic orderings so the sidebar never jumps: chains by title then id,
// agents/members by display_name then instance id.
agents_live_chain_less :: proc(a, b: Agents_Live_Chain) -> bool {
	if a.title != b.title do return a.title < b.title
	return a.chain_id < b.chain_id
}
agents_live_agent_less :: proc(a, b: Agents_Live_Agent) -> bool {
	if a.display_name != b.display_name do return a.display_name < b.display_name
	return a.agent_instance_id < b.agent_instance_id
}
agents_live_member_less :: proc(a, b: Agents_Live_Member) -> bool {
	if a.display_name != b.display_name do return a.display_name < b.display_name
	return a.agent_instance_id < b.agent_instance_id
}

// build_agents_live_tree assembles the projects->live-chains->agents tree from
// already-fetched data. It is kept pure (no services) so it is unit-testable
// without a DB. Inputs:
//   projects          all of the owner's projects
//   chains            all of the owner's chains
//   members_by_chain  chain_id -> its canonical member roster (incl. non-live)
//   instances_by_id   agent_instance_id -> instance (liveness + project + labels)
// A chain is emitted only when it has >=1 live agent; its project is the
// coordinator instance's project (else the first live agent's project). Projects
// are alphabetical by name; a trailing "Unassigned" bucket (project_id "") holds
// any live chain that resolves to no known project. String fields are VIEWS into
// the inputs (valid for the request); the JSON serializer copies them out. The
// returned tree is caller-owned — free it with free_agents_live_tree.
build_agents_live_tree :: proc(projects: []domain.Project, chains: []domain.Task_Chain, members_by_chain: map[string][]domain.Task_Chain_Member, instances_by_id: map[string]domain.Agent_Instance) -> []Agents_Live_Project {
	// 1) Build each live chain and remember its resolved project id (parallel).
	live_chains := make([dynamic]Agents_Live_Chain); defer delete(live_chains)
	project_of_chain := make([dynamic]string); defer delete(project_of_chain)
	for chain in chains {
		members := members_by_chain[string(chain.chain_id)] or_else nil
		// Canonical coordinator (H9): the earliest member with role "coordinator";
		// members come ordered by created_at ASC. Fall back to the derived mirror.
		coordinator_id := chain.coordinator_agent_instance_id
		for m in members {
			if m.role == "coordinator" { coordinator_id = m.agent_instance_id; break }
		}
		agents := make([dynamic]Agents_Live_Agent)
		roster := make([dynamic]Agents_Live_Member)
		for m in members {
			inst, has_inst := instances_by_id[m.agent_instance_id]
			live := has_inst && agent_service.runtime_expected_active(inst.runtime_status)
			is_coord := m.agent_instance_id == coordinator_id
			append(&roster, Agents_Live_Member{
				agent_instance_id = m.agent_instance_id,
				display_name = inst.display_name if has_inst else "",
				role = m.role,
				is_coordinator = is_coord,
				is_live = live,
				runtime_status = inst.runtime_status if has_inst else "",
			})
			if live {
				append(&agents, Agents_Live_Agent{
					agent_instance_id = m.agent_instance_id,
					display_name = inst.display_name,
					is_coordinator = is_coord,
					runtime_status = inst.runtime_status,
					activity_status = inst.activity_status,
				})
			}
		}
		if len(agents) == 0 { delete(agents); delete(roster); continue }
		slice.sort_by(agents[:], agents_live_agent_less)
		slice.sort_by(roster[:], agents_live_member_less)
		project_id := ""
		if coord_inst, ok := instances_by_id[coordinator_id]; ok do project_id = string(coord_inst.project_id)
		if project_id == "" {
			for a in agents {
				if inst, ok := instances_by_id[a.agent_instance_id]; ok && string(inst.project_id) != "" { project_id = string(inst.project_id); break }
			}
		}
		append(&live_chains, Agents_Live_Chain{
			chain_id = string(chain.chain_id),
			title = chain.title,
			coordinator_agent_instance_id = coordinator_id,
			live_agents = agents[:],
			members = roster[:],
		})
		append(&project_of_chain, project_id)
	}

	// 2) Bucket live chains by their resolved project id.
	chains_by_project := make(map[string][dynamic]Agents_Live_Chain)
	defer { for _, bkt in chains_by_project do delete(bkt); delete(chains_by_project) }
	for lc, i in live_chains {
		pid := project_of_chain[i]
		if pid not_in chains_by_project do chains_by_project[pid] = make([dynamic]Agents_Live_Chain)
		append(&chains_by_project[pid], lc)
	}

	// 3) Emit ALL projects alphabetically, attaching their live chains; then a
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
		append(&out, Agents_Live_Project{ project_id = pid, name = p.name, chains = agents_live_copy_sorted_chains(bucket[:]) })
	}
	unassigned := make([dynamic]Agents_Live_Chain); defer delete(unassigned)
	for pid, bucket in chains_by_project {
		if matched[pid] do continue
		for lc in bucket do append(&unassigned, lc)
	}
	if len(unassigned) > 0 {
		append(&out, Agents_Live_Project{ project_id = "", name = "Unassigned", chains = agents_live_copy_sorted_chains(unassigned[:]) })
	}
	return out[:]
}

// agents_live_copy_sorted_chains copies a bucket into a fresh owned slice sorted
// by agents_live_chain_less. The copied structs share the live_agents/members
// backing arrays (single ownership: each live chain lands in exactly one bucket).
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

write_task_comment_json :: proc(b: ^strings.Builder, c: domain.Task_Comment) {
	strings.write_string(b, "{\"comment_id\":\""); write_handler_json_string(b, c.comment_id)
	strings.write_string(b, "\",\"task_id\":\""); write_handler_json_string(b, string(c.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id))
	strings.write_string(b, "\",\"author_agent_instance_id\":\""); write_handler_json_string(b, c.author_agent_instance_id)
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

write_task_comment_response_json :: proc(b: ^strings.Builder, c: domain.Task_Comment, notified: []string) {
	strings.write_string(b, "{\"comment_id\":\""); write_handler_json_string(b, c.comment_id)
	strings.write_string(b, "\",\"task_id\":\""); write_handler_json_string(b, string(c.task_id))
	strings.write_string(b, "\",\"chain_id\":\""); write_handler_json_string(b, string(c.chain_id))
	strings.write_string(b, "\",\"author_agent_instance_id\":\""); write_handler_json_string(b, c.author_agent_instance_id)
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
chain_status_http :: proc(status: domain.Task_Chain_Status) -> string { if status == .Completed do return "completed"; if status == .Cancelled do return "cancelled"; return "active" }
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

require_task_path_scope :: proc(h: ^Taskchain_Handlers, auth_ctx: contracts.Auth_Context, chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID, req: Request) -> (bool, Response) {
	task, ok, err := taskchain_service.get_task(h.taskchains, auth_ctx, task_id)
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
