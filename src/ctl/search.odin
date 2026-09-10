package main

import "core:fmt"
import "core:os"
import "core:strings"
import json "core:encoding/json"
import http "odin_test:lib/http_client"

// ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--json]
//
// Calls the Hub GET /api/v1/search with the SEARCH-2/8 params:
//   --scope     -> types      (CSV of scopes/resource types: agent,task,comment,skill,…)
//   typed per-parent id filters (CSV each): --task-ids/--chain-ids/--project-ids/
//     --conversation-ids and negations --not-in-task-ids/-chain-ids/-project-ids/-conversation-ids
//   --exclude   -> exclude    (drop hits whose text contains this substring)
//   --limit     -> limit      (page size; server clamps to its max)
// Default output is grouped, human-readable, with a preview line per hit; it
// follows next_cursor to page in the full result set. --json prints the raw
// first-page envelope (which carries next_cursor/has_more for scripted paging).

SEARCH_MAX_PAGES :: 20

// Search_Row is the flattened hit used for grouped human output.
Search_Row :: struct {
	type:          string,
	label:         string,
	sublabel:      string,
	route:         string,
	preview:       string,
	matched_field: string,
}

print_search_help :: proc() {
	fmt.println("ham-ctl search <query> [--scope csv] [typed id filters] [--exclude text] [--limit n] [--json]")
	fmt.println("Purpose: global entity search across the Hub (GET /api/v1/search).")
	fmt.println("Flags:")
	fmt.println("  --scope             CSV of scopes: conversation,agent,agent_instance,task-chain,")
	fmt.println("                      task,comment,project,artifact,memory,skill (default: all)")
	fmt.println("  Typed parent-id filters (CSV; keep only rows under the named parent):")
	fmt.println("    --task-ids, --chain-ids, --project-ids, --conversation-ids")
	fmt.println("  Negations (CSV; drop rows under the named parent):")
	fmt.println("    --not-in-task-ids, --not-in-chain-ids, --not-in-project-ids, --not-in-conversation-ids")
	fmt.println("  --exclude           Drop hits whose text contains this substring")
	fmt.println("  --limit             Page size (server clamps to its max); human mode pages via the cursor")
	fmt.println("  --json              Print the raw response envelope (carries next_cursor/has_more)")
	fmt.println("Auth: needs --hub-url + --user-token (or HAM_HUB_URL / HAM_HUB_USER_TOKEN).")
	fmt.println("Examples:")
	fmt.println("  ham-ctl search 'deploy runbook' --hub-url http://127.0.0.1:49322 --user-token hut_...")
	fmt.println("  ham-ctl search zebra --scope task,comment --chain-ids chain_123 --limit 20")
	fmt.println("  ham-ctl search zebra --project-ids proj_1 --not-in-chain-ids chain_9")
}

ctl_search_command :: proc(cmd: []string, args: []string) {
	query := ""
	if len(cmd) >= 2 do query = cmd[1]
	if strings.trim_space(query) == "" {
		fmt.println(`{"ok":false,"message":"usage: ham-ctl search <query> [--scope csv] [--task-ids/--chain-ids/--project-ids/--conversation-ids csv] [--not-in-* csv] [--exclude text] [--limit n] [--json]"}`)
		os.exit(1)
	}
	base := hub_user_mode_url(args)
	if base == "" do base = "http://127.0.0.1:49328"
	base = strings.trim_right(base, "/")
	token := hub_user_mode_token(args)

	// --json: single request, print the structured envelope verbatim.
	if has_flag(args, "--json") {
		body, ok := ctl_search_fetch(base, token, ctl_build_search_path(args, query, ""))
		if !ok { fmt.println(`{"ok":false,"message":"Hub request failed"}`); os.exit(1) }
		fmt.println(body)
		return
	}

	// Human output: page through with the cursor and aggregate. Each row owns its
	// strings (cloned in ctl_search_collect) so they survive the per-page JSON tree
	// being destroyed; free them all once printing is done.
	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}
	// cursor holds a cloned (owned) next_cursor between pages; "" is the unallocated
	// literal start/end sentinel, so only free it when it points at a clone.
	cursor := ""
	defer if cursor != "" do delete(cursor)
	for _ in 0..<SEARCH_MAX_PAGES {
		body, ok := ctl_search_fetch(base, token, ctl_build_search_path(args, query, cursor))
		if !ok { fmt.println("search request failed"); os.exit(1) }
		next, perr := ctl_search_collect(body, &rows)
		if perr {
			// Fall back to raw output if the body isn't the expected shape.
			fmt.println(body)
			return
		}
		if cursor != "" do delete(cursor)
		cursor = next
		if cursor == "" do break
	}
	ctl_print_search_rows(rows[:], query)
}

// ctl_build_search_path is the pure param-builder (unit-tested). It percent-
// encodes each value and omits any flag the caller didn't provide.
ctl_build_search_path :: proc(args: []string, query, cursor: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "/api/v1/search?q=")
	write_query_escaped(&b, strings.trim_space(query))
	append_search_param(&b, "types", option_value(args, "--scope", ""))
	append_search_param(&b, "task_ids", option_value(args, "--task-ids", ""))
	append_search_param(&b, "chain_ids", option_value(args, "--chain-ids", ""))
	append_search_param(&b, "project_ids", option_value(args, "--project-ids", ""))
	append_search_param(&b, "conversation_ids", option_value(args, "--conversation-ids", ""))
	append_search_param(&b, "not_in_task_ids", option_value(args, "--not-in-task-ids", ""))
	append_search_param(&b, "not_in_chain_ids", option_value(args, "--not-in-chain-ids", ""))
	append_search_param(&b, "not_in_project_ids", option_value(args, "--not-in-project-ids", ""))
	append_search_param(&b, "not_in_conversation_ids", option_value(args, "--not-in-conversation-ids", ""))
	append_search_param(&b, "exclude", option_value(args, "--exclude", ""))
	append_search_param(&b, "limit", option_value(args, "--limit", ""))
	append_search_param(&b, "cursor", cursor)
	return strings.to_string(b)
}

append_search_param :: proc(b: ^strings.Builder, key, value: string) {
	if value == "" do return
	strings.write_byte(b, '&')
	strings.write_string(b, key)
	strings.write_byte(b, '=')
	write_query_escaped(b, value)
}

// write_query_escaped percent-encodes per RFC 3986 (unreserved chars pass through,
// everything else is %XX). Operates byte-wise so UTF-8 is encoded correctly.
write_query_escaped :: proc(b: ^strings.Builder, s: string) {
	for i in 0..<len(s) {
		ch := s[i]
		switch ch {
		case 'A'..='Z', 'a'..='z', '0'..='9', '-', '_', '.', '~':
			strings.write_byte(b, ch)
		case:
			strings.write_byte(b, '%')
			strings.write_byte(b, hex_upper_digit(ch >> 4))
			strings.write_byte(b, hex_upper_digit(ch & 0x0F))
		}
	}
}

hex_upper_digit :: proc(n: byte) -> byte {
	if n < 10 do return '0' + n
	return 'A' + (n - 10)
}

ctl_search_fetch :: proc(base, token, path: string) -> (string, bool) {
	full_path := hub_url_path_prefix_join(base, path)
	headers := [?]http.Header{{name = "Authorization", value = strings.concatenate({"Bearer ", token})}}
	response, ok := http.request_with_headers_timeout("GET", base, full_path, "", headers[:], http.DEFAULT_TIMEOUT_MS)
	if !ok do return "", false
	return response.body, true
}

// ctl_search_collect parses one page envelope, appends its hits to rows, and
// returns the next cursor ("" when there is no more). perr is true when the
// body is not the expected {"data":{"groups":[…]},"page":{…}} shape.
ctl_search_collect :: proc(body: string, rows: ^[dynamic]Search_Row) -> (next_cursor: string, perr: bool) {
	value, err := json.parse(transmute([]byte)body)
	if err != .None do return "", true
	defer json.destroy_value(value)
	root, is_obj := value.(json.Object)
	if !is_obj do return "", true
	data, has_data := root["data"].(json.Object)
	if !has_data do return "", true
	groups, has_groups := data["groups"].(json.Array)
	if !has_groups do return "", true
	for group_value in groups {
		group, gok := group_value.(json.Object)
		if !gok do continue
		gtype := json_field_string(group, "type")
		hits, hok := group["hits"].(json.Array)
		if !hok do continue
		for hit_value in hits {
			hit, hitok := hit_value.(json.Object)
			if !hitok do continue
			// json_field_string returns a slice INTO the parsed tree, which the
			// deferred destroy_value frees when this proc returns. Clone every field
			// (gtype per row, so no two rows share a backing) so the rows can outlive
			// the page's JSON tree; ctl_search_command frees them via search_row_delete.
			append(rows, Search_Row{
				type          = strings.clone(gtype),
				label         = strings.clone(json_field_string(hit, "label")),
				sublabel      = strings.clone(json_field_string(hit, "sublabel")),
				route         = strings.clone(json_field_string(hit, "route")),
				preview       = strings.clone(json_field_string(hit, "preview")),
				matched_field = strings.clone(json_field_string(hit, "matched_field")),
			})
		}
	}
	// Only follow the cursor when the server says there is more.
	if page, has_page := root["page"].(json.Object); has_page {
		has_more, _ := page["has_more"].(json.Boolean)
		// Clone the cursor too: it points into the tree destroy_value frees below, so
		// the caller would otherwise read freed memory when building the next page.
		if has_more do return strings.clone(json_field_string(page, "next_cursor")), false
	}
	return "", false
}

// search_row_delete frees the strings a Search_Row owns (cloned in
// ctl_search_collect so the row can outlive the parsed JSON tree it came from).
search_row_delete :: proc(row: Search_Row) {
	delete(row.type)
	delete(row.label)
	delete(row.sublabel)
	delete(row.route)
	delete(row.preview)
	delete(row.matched_field)
}

json_field_string :: proc(obj: json.Object, key: string) -> string {
	if s, ok := obj[key].(json.String); ok do return string(s)
	return ""
}

// SEARCH_GROUP_ORDER mirrors the server's group ordering so the CLI is stable.
SEARCH_GROUP_ORDER :: [?]string{"conversation", "agent", "agent_instance", "task-chain", "task", "comment", "project", "artifact", "memory", "skill"}

ctl_print_search_rows :: proc(rows: []Search_Row, query: string) {
	if len(rows) == 0 {
		fmt.printfln("No results for %q.", query)
		return
	}
	for group_type in SEARCH_GROUP_ORDER {
		ctl_print_search_group(rows, group_type)
	}
	// Print any unexpected type once, so nothing is silently dropped.
	seen := make(map[string]bool)
	defer delete(seen)
	for row in rows {
		if search_type_in_order(row.type) || seen[row.type] do continue
		seen[row.type] = true
		ctl_print_search_group(rows, row.type)
	}
	fmt.printfln("%d result%s.", len(rows), len(rows) == 1 ? "" : "s")
}

ctl_print_search_group :: proc(rows: []Search_Row, group_type: string) {
	count := 0
	for row in rows do if row.type == group_type do count += 1
	if count == 0 do return
	fmt.printfln("%s (%d)", search_group_label(group_type), count)
	for row in rows {
		if row.type != group_type do continue
		if row.sublabel != "" {
			fmt.printfln("  • %s  —  %s", row.label, row.sublabel)
		} else {
			fmt.printfln("  • %s", row.label)
		}
		if row.route != "" do fmt.printfln("      %s", row.route)
		if row.preview != "" do fmt.printfln("      %s", row.preview)
	}
	fmt.println("")
}

search_type_in_order :: proc(t: string) -> bool {
	for candidate in SEARCH_GROUP_ORDER do if candidate == t do return true
	return false
}

search_group_label :: proc(t: string) -> string {
	switch t {
	case "conversation":   return "Conversations"
	case "agent":          return "Agents"
	case "agent_instance": return "Agent instances"
	case "task-chain":     return "Task chains"
	case "task":           return "Tasks"
	case "comment":        return "Comments"
	case "project":        return "Projects"
	case "artifact":       return "Artifacts"
	case "memory":         return "Memories"
	case "skill":          return "Skills"
	}
	return t
}
