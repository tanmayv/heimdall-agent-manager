#+private file
// The owed-review lookup (lease next and the matcher, once per fleet agent per
// match) must read one chain's in_review tasks, not every task of the owner.
// No ANALYZE is run: production never runs it, so this is the plan production
// gets on any database, empty or not.
package sqlite

import "core:strings"
import "core:testing"

orp_plan :: proc(conn: ^Conn, query: string) -> string {
	stmt: sqlite3_stmt = nil
	full := strings.concatenate({"EXPLAIN QUERY PLAN ", query}, context.temp_allocator)
	if sqlite3_prepare_v2(conn.db, strings.clone_to_cstring(full, context.temp_allocator), -1, &stmt, nil) != SQLITE_OK do return ""
	defer sqlite3_finalize(stmt)
	b := strings.builder_make(context.temp_allocator)
	for sqlite3_step(stmt) == SQLITE_ROW {
		strings.write_string(&b, column_text_unowned(stmt, 3))
		strings.write_string(&b, "\n")
	}
	return strings.to_string(b)
}

@(test)
test_owed_reviews_plan_reads_one_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, path, ok := tmpl_open_file_prod(t, "owed_reviews_plan")
	if !ok do return
	defer tmpl_remove_db(path)
	defer close(&conn)
	mig_ok, err := run_migrations(&conn)
	if !testing.expect(t, mig_ok, err.message) do return

	plan := orp_plan(&conn, OWED_REVIEWS_QUERY)
	if !testing.expect(t, plan != "", "EXPLAIN QUERY PLAN prepares") do return
	// The outer read is a (chain_id, state) range on tasks, or starts from the
	// chain's reviewer rows; either is bounded by one chain.
	bounded := strings.contains(plan, "SEARCH t USING INDEX idx_tasks_chain_state (chain_id=? AND state=?)") ||
		strings.contains(plan, "SEARCH r USING INDEX idx_task_reviewers_chain_agent (chain_id=? AND agent_id=?)")
	testing.expectf(t, bounded, "owed reviews must read one chain:\n%s", plan)
	testing.expectf(t, !strings.contains(plan, "idx_search_tasks_owner_lower_title"), "owed reviews must not walk every task of the owner:\n%s", plan)
}
