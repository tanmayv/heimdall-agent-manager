package main

import "core:strings"
import "core:testing"

// Unit coverage for the pure ham-ctl search param-builder. It must map the CLI
// flags onto the query params (--scope=>types; typed --task-ids/--chain-ids/
// --project-ids/--conversation-ids + --not-in-* negations; --exclude; --limit;
// plus the load-more cursor), percent-encode each value, and OMIT any flag the
// caller didn't provide. --scope-ids is REMOVED (SEARCH-8).

@(test)
test_search_path_query_only :: proc(t: ^testing.T) {
	path := ctl_build_search_path([]string{}, "hello world", "")
	testing.expect(t, path == "/api/v1/search?q=hello%20world", path)
}

@(test)
test_search_path_omits_absent_flags :: proc(t: ^testing.T) {
	path := ctl_build_search_path([]string{}, "q", "")
	testing.expect(t, !strings.contains(path, "types="), "types omitted when --scope absent")
	testing.expect(t, !strings.contains(path, "task_ids="), "task_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "chain_ids="), "chain_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "project_ids="), "project_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "conversation_ids="), "conversation_ids omitted when absent")
	testing.expect(t, !strings.contains(path, "not_in_"), "negations omitted when absent")
	testing.expect(t, !strings.contains(path, "scope_ids"), "scope_ids must be gone (SEARCH-8)")
	testing.expect(t, !strings.contains(path, "exclude="), "exclude omitted when --exclude absent")
	testing.expect(t, !strings.contains(path, "limit="), "limit omitted when --limit absent")
	testing.expect(t, !strings.contains(path, "cursor="), "cursor omitted when empty")
}

@(test)
test_search_path_maps_all_flags :: proc(t: ^testing.T) {
	args := []string{
		"--scope", "task,comment",
		"--chain-ids", "chain_1,chain_2",
		"--task-ids", "task_9",
		"--project-ids", "proj_1",
		"--conversation-ids", "inst_5",
		"--exclude", "draft",
		"--limit", "25",
	}
	path := ctl_build_search_path(args, "zebra", "")
	testing.expect(t, strings.contains(path, "q=zebra"), path)
	testing.expect(t, strings.contains(path, "&types=task%2Ccomment"), path)          // comma encoded
	testing.expect(t, strings.contains(path, "&task_ids=task_9"), path)
	testing.expect(t, strings.contains(path, "&chain_ids=chain_1%2Cchain_2"), path)
	testing.expect(t, strings.contains(path, "&project_ids=proj_1"), path)
	testing.expect(t, strings.contains(path, "&conversation_ids=inst_5"), path)
	testing.expect(t, strings.contains(path, "&exclude=draft"), path)
	testing.expect(t, strings.contains(path, "&limit=25"), path)
	testing.expect(t, !strings.contains(path, "scope_ids"), "scope_ids must be gone")
}

@(test)
test_search_path_negations :: proc(t: ^testing.T) {
	args := []string{
		"--not-in-task-ids", "task_1",
		"--not-in-chain-ids", "chain_1",
		"--not-in-project-ids", "proj_1",
		"--not-in-conversation-ids", "inst_1",
	}
	path := ctl_build_search_path(args, "q", "")
	testing.expect(t, strings.contains(path, "&not_in_task_ids=task_1"), path)
	testing.expect(t, strings.contains(path, "&not_in_chain_ids=chain_1"), path)
	testing.expect(t, strings.contains(path, "&not_in_project_ids=proj_1"), path)
	testing.expect(t, strings.contains(path, "&not_in_conversation_ids=inst_1"), path)
}

@(test)
test_search_path_encodes_reserved_chars :: proc(t: ^testing.T) {
	path := ctl_build_search_path([]string{"--exclude", "a&b=c d"}, "x/y?z", "")
	// Reserved characters must be percent-encoded so they don't break the query.
	testing.expect(t, strings.contains(path, "q=x%2Fy%3Fz"), path)
	testing.expect(t, strings.contains(path, "exclude=a%26b%3Dc%20d"), path)
	// Unreserved punctuation passes through unescaped.
	keep := ctl_build_search_path([]string{}, "a-b_c.d~e", "")
	testing.expect(t, strings.contains(keep, "q=a-b_c.d~e"), keep)
}

@(test)
test_search_path_appends_cursor :: proc(t: ^testing.T) {
	path := ctl_build_search_path([]string{}, "q", "Y3Vyc29y")
	testing.expect(t, strings.has_suffix(path, "&cursor=Y3Vyc29y"), path)
}
