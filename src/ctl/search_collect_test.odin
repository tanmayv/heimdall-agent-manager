package main

import "core:testing"

// Unit coverage for ctl_search_collect, guarding the SEARCH-12 use-after-free fix.
// ctl_search_collect parses a page envelope, appends its hits to `rows`, and then
// destroys the parsed JSON tree (its `defer json.destroy_value`) BEFORE returning.
// The row/cursor strings must therefore be cloned; if they were still slices into
// the freed tree, the assertions below would read garbage.

@(test)
test_search_collect_rows_survive_tree_destroy :: proc(t: ^testing.T) {
	// One group ("task") with two hits; the second omits sublabel. has_more=false.
	body := `{"data":{"groups":[{"type":"task","hits":[` +
		`{"label":"Alpha","sublabel":"chain_1","route":"/t/1","preview":"do the thing","matched_field":"title"},` +
		`{"label":"Beta","route":"/t/2","preview":"another","matched_field":"body"}` +
		`]}]},"page":{"has_more":false}}`

	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}

	next, perr := ctl_search_collect(body, &rows)
	testing.expect(t, !perr, "well-formed envelope should parse")
	testing.expect_value(t, next, "")
	testing.expect_value(t, len(rows), 2)

	// Rows are read AFTER ctl_search_collect destroyed its source tree — intact
	// values here prove the strings are owned clones, not dangling slices.
	testing.expect_value(t, rows[0].type, "task")
	testing.expect_value(t, rows[0].label, "Alpha")
	testing.expect_value(t, rows[0].sublabel, "chain_1")
	testing.expect_value(t, rows[0].route, "/t/1")
	testing.expect_value(t, rows[0].preview, "do the thing")
	testing.expect_value(t, rows[0].matched_field, "title")

	testing.expect_value(t, rows[1].type, "task")
	testing.expect_value(t, rows[1].label, "Beta")
	testing.expect_value(t, rows[1].sublabel, "")
	testing.expect_value(t, rows[1].route, "/t/2")
}

@(test)
test_search_collect_clones_next_cursor :: proc(t: ^testing.T) {
	// has_more=true => the caller keeps paging with next_cursor. That cursor also
	// points into the tree destroy_value frees, so it must be a clone.
	body := `{"data":{"groups":[]},"page":{"has_more":true,"next_cursor":"Y3Vyc29y"}}`

	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}

	next, perr := ctl_search_collect(body, &rows)
	testing.expect(t, !perr, "well-formed envelope should parse")
	testing.expect_value(t, next, "Y3Vyc29y")
	delete(next) // owned clone — free it so the test doesn't leak
}

@(test)
test_search_collect_rejects_malformed_body :: proc(t: ^testing.T) {
	// Not the expected {"data":{"groups":[…]}} shape => perr so the CLI can fall
	// back to raw output; no rows appended, cursor empty.
	rows := make([dynamic]Search_Row)
	defer {
		for row in rows do search_row_delete(row)
		delete(rows)
	}

	next, perr := ctl_search_collect(`{"unexpected":true}`, &rows)
	testing.expect(t, perr, "unexpected shape should report perr")
	testing.expect_value(t, next, "")
	testing.expect_value(t, len(rows), 0)
}
