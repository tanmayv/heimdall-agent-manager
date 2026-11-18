package sqlite

import "core:encoding/json"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Agent_Write_Repo_SQLite :: struct {
	conn: ^Conn,
}
new_agent_write_repository :: proc(impl: ^Agent_Write_Repo_SQLite, conn: ^Conn) -> iface.Agent_Write_Repository {
	impl.conn = conn
	return {ctx = impl, insert = agent_write_insert_sqlite, list_by_owner = agent_write_list_by_owner_sqlite}
}
agent_write_insert_sqlite :: proc(ctx: rawptr, w: domain.Agent_Write) -> domain.Domain_Error {
	impl := (^Agent_Write_Repo_SQLite)(ctx)
	fields := w.fields
	if fields == nil do fields = []string{}
	encoded, marshal_err := json.marshal(fields)
	if marshal_err != nil do return domain.domain_error(.Internal_Error, "agent write fields encoding failed")
	defer delete(encoded)
	_, err := bot_repo_write(
		impl.conn,
		`
INSERT INTO agent_writes (write_id, owner_user_id, actor_agent_instance_id, actor_agent_id, resource_kind, resource_id, action, fields_json, created_at)
VALUES ('awr_' || lower(hex(randomblob(8))), ?, ?,
	COALESCE((SELECT agent_id FROM agent_instances WHERE agent_instance_id = ? AND owner_user_id = ?), ''),
	?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));`,
		[]string {
			w.owner_user_id,
			w.actor_agent_instance_id,
			w.actor_agent_instance_id,
			w.owner_user_id,
			w.resource_kind,
			w.resource_id,
			w.action,
			string(encoded),
		},
	)
	return err
}
agent_write_list_by_owner_sqlite :: proc(
	ctx: rawptr,
	owner_user_id: string,
	before_seq: i64,
	limit: int,
) -> (
	[]domain.Agent_Write,
	domain.Domain_Error,
) {
	impl := (^Agent_Write_Repo_SQLite)(ctx)
	stmt, err := bot_repo_prepare(
		impl.conn,
		`
SELECT w.seq, w.write_id, w.owner_user_id, w.actor_agent_instance_id, w.actor_agent_id,
	COALESCE(i.display_name, ''), w.resource_kind, w.resource_id, w.action, w.fields_json, w.created_at
FROM agent_writes w
LEFT JOIN agent_instances i ON i.agent_instance_id = w.actor_agent_instance_id AND i.owner_user_id = w.owner_user_id
WHERE w.owner_user_id = ? AND (? <= 0 OR w.seq < ?)
ORDER BY w.seq DESC LIMIT ?;`,
		[]string{owner_user_id},
	)
	if err.code != .None do return nil, err
	defer sqlite3_finalize(stmt)
	if sqlite3_bind_int64(stmt, 2, before_seq) != SQLITE_OK ||
	   sqlite3_bind_int64(stmt, 3, before_seq) != SQLITE_OK ||
	   sqlite3_bind_int64(stmt, 4, i64(limit)) != SQLITE_OK {
		return nil, domain.domain_error(.Internal_Error, "agent write query binding failed")
	}
	rows := make([dynamic]domain.Agent_Write)
	for {
		rc := sqlite3_step(stmt)
		if rc == SQLITE_DONE do break
		if rc != SQLITE_ROW {
			for &row in rows do domain.agent_write_destroy(&row)
			delete(rows)
			return nil, domain.domain_error(.Internal_Error, "agent write query failed")
		}
		w := domain.Agent_Write {
			seq                     = i64(sqlite3_column_int64(stmt, 0)),
			write_id                = column_text(stmt, 1),
			owner_user_id           = column_text(stmt, 2),
			actor_agent_instance_id = column_text(stmt, 3),
			actor_agent_id          = column_text(stmt, 4),
			actor_display_name      = column_text(stmt, 5),
			resource_kind           = column_text(stmt, 6),
			resource_id             = column_text(stmt, 7),
			action                  = column_text(stmt, 8),
			created_at              = column_text(stmt, 10),
		}
		if decode_err := json.unmarshal(transmute([]u8)column_text_unowned(stmt, 9), &w.fields); decode_err != nil {
			domain.agent_write_destroy(&w)
			for &row in rows do domain.agent_write_destroy(&row)
			delete(rows)
			return nil, domain.domain_error(.Internal_Error, "agent write fields decoding failed")
		}
		append(&rows, w)
	}
	return rows[:], {}
}
