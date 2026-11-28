package sqlite

import "core:fmt"
import domain "odin_test:hub/domain"

bot_web_activation_get_sqlite :: proc(ctx: rawptr, owner: string) -> (domain.Bot_Web_Activation, bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	stmt, err := bot_repo_prepare(conn, "SELECT owner_user_id, bot_id, agent_instance_id, conversation_id, enabled, generation FROM bot_web_activations WHERE owner_user_id = ?;", {owner})
	if err.code != .None do return {}, false, err
	defer sqlite3_finalize(stmt)
	switch sqlite3_step(stmt) {
	case SQLITE_DONE: return {}, false, {}
	case SQLITE_ROW:
		return {
			owner_user_id = column_text(stmt, 0), bot_id = column_text(stmt, 1),
			agent_instance_id = column_text(stmt, 2), conversation_id = column_text(stmt, 3),
			enabled = sqlite3_column_int64(stmt, 4) != 0, generation = i64(sqlite3_column_int64(stmt, 5)),
		}, true, {}
	}
	return {}, false, bot_repo_error(conn)
}

bot_web_activation_insert_sqlite :: proc(ctx: rawptr, row: domain.Bot_Web_Activation) -> domain.Domain_Error {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	conn := bot_repo_conn(ctx)
	_, err := bot_repo_write(conn, "INSERT INTO bot_web_activations (owner_user_id, bot_id, agent_instance_id, conversation_id, enabled, generation) VALUES (?, ?, ?, ?, 1, 1);",
		{row.owner_user_id, row.bot_id, row.agent_instance_id, row.conversation_id})
	return err
}

bot_web_activation_set_enabled_sqlite :: proc(ctx: rawptr, owner: string, enabled: bool, expected_generation: i64) -> (bool, domain.Domain_Error) {
	guard := tx_repository_enter()
	defer tx_repository_leave(guard)
	changes, err := bot_repo_write(bot_repo_conn(ctx),
		"UPDATE bot_web_activations SET enabled = ?1, generation = generation + 1 WHERE owner_user_id = ?2 AND generation = ?3 AND enabled != ?1;",
		{"1" if enabled else "0", owner, fmt.tprintf("%d", expected_generation)})
	return changes == 1, err
}
