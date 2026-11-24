package sqlite

import "core:strings"
import domain "odin_test:hub/domain"

ACP_INPUT_DELIVERY_COLUMNS :: "message_id,owner_user_id,conversation_id,agent_instance_id,launch_epoch,state,hold_reason,mode,turn_id,batch_id,error,report_seq,created_at,updated_at,delivered_at,agent_read_at"
ACP_SEND_NOW_BATCH_COLUMNS :: "batch_id,owner_user_id,conversation_id,agent_instance_id,launch_epoch,request_id,attempt,state,error,member_ids_json,excluded_json,created_at,updated_at"

acp_input_delivery_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.ACP_Input_Delivery {
    return {message_id=column_text(stmt,0), owner_user_id=column_text(stmt,1), conversation_id=column_text(stmt,2), agent_instance_id=column_text(stmt,3),
        launch_epoch=column_text(stmt,4), state=column_text(stmt,5), hold_reason=column_text(stmt,6), mode=column_text(stmt,7), turn_id=column_text(stmt,8),
        batch_id=column_text(stmt,9), error=column_text(stmt,10), report_seq=sqlite3_column_int64(stmt,11), created_at=column_text(stmt,12),
        updated_at=column_text(stmt,13), delivered_at=column_text(stmt,14), agent_read_at=column_text(stmt,15)}
}

acp_send_now_batch_from_stmt :: proc(stmt: sqlite3_stmt) -> domain.ACP_Send_Now_Batch {
    return {batch_id=column_text(stmt,0), owner_user_id=column_text(stmt,1), conversation_id=column_text(stmt,2), agent_instance_id=column_text(stmt,3),
        launch_epoch=column_text(stmt,4), request_id=column_text(stmt,5), attempt=sqlite3_column_int64(stmt,6), state=column_text(stmt,7),
        error=column_text(stmt,8), member_ids_json=column_text(stmt,9), excluded_json=column_text(stmt,10), created_at=column_text(stmt,11), updated_at=column_text(stmt,12)}
}

content_get_input_delivery_sqlite :: proc(ctx: rawptr, message_id: string) -> (domain.ACP_Input_Delivery, bool, domain.Domain_Error) {
    impl := cast(^Content_Repo_SQLite)ctx
    q := "SELECT " + ACP_INPUT_DELIVERY_COLUMNS + " FROM acp_input_deliveries WHERE message_id=?;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed input delivery lookup")
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, message_id)
    rc := sqlite3_step(stmt)
    if rc == SQLITE_DONE do return {}, false, {}
    if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed input delivery lookup")
    return acp_input_delivery_from_stmt(stmt), true, {}
}

content_save_input_delivery_sqlite :: proc(ctx: rawptr, row: domain.ACP_Input_Delivery) -> domain.Domain_Error {
    guard := tx_repository_enter()
    defer tx_repository_leave(guard)
    impl := cast(^Content_Repo_SQLite)ctx
    q := "INSERT INTO acp_input_deliveries(" + ACP_INPUT_DELIVERY_COLUMNS + ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) " +
        "ON CONFLICT(message_id) DO UPDATE SET launch_epoch=excluded.launch_epoch,state=excluded.state,hold_reason=excluded.hold_reason,mode=excluded.mode," +
        "turn_id=excluded.turn_id,batch_id=excluded.batch_id,error=excluded.error,report_seq=excluded.report_seq,updated_at=excluded.updated_at," +
        "delivered_at=excluded.delivered_at,agent_read_at=excluded.agent_read_at;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed input delivery save")
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,row.message_id); bind_text(stmt,2,row.owner_user_id); bind_text(stmt,3,row.conversation_id); bind_text(stmt,4,row.agent_instance_id)
    bind_text(stmt,5,row.launch_epoch); bind_text(stmt,6,row.state); bind_text(stmt,7,row.hold_reason); bind_text(stmt,8,row.mode)
    bind_text(stmt,9,row.turn_id); bind_text(stmt,10,row.batch_id); bind_text(stmt,11,row.error); sqlite3_bind_int64(stmt,12,row.report_seq)
    bind_text(stmt,13,row.created_at); bind_text(stmt,14,row.updated_at); bind_text(stmt,15,row.delivered_at); bind_text(stmt,16,row.agent_read_at)
    if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "input delivery could not be saved")
    return {}
}

content_list_open_input_deliveries_sqlite :: proc(ctx: rawptr, conversation_id, agent_instance_id: string) -> ([]domain.ACP_Input_Delivery, domain.Domain_Error) {
    impl := cast(^Content_Repo_SQLite)ctx
    filter := "conversation_id=?" if conversation_id != "" else "agent_instance_id=?"
    q := strings.concatenate({"SELECT ", ACP_INPUT_DELIVERY_COLUMNS, " FROM acp_input_deliveries WHERE ", filter,
        " AND state IN ('sent','queued','dispatching') ORDER BY created_at, rowid;"}, context.temp_allocator)
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return nil, domain.domain_error(.Internal_Error, "failed input delivery list")
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, conversation_id if conversation_id != "" else agent_instance_id)
    rows := make([dynamic]domain.ACP_Input_Delivery)
    for {
        rc := sqlite3_step(stmt)
        if rc == SQLITE_DONE do break
        if rc != SQLITE_ROW do return nil, domain.domain_error(.Internal_Error, "failed input delivery list")
        append(&rows, acp_input_delivery_from_stmt(stmt))
    }
    return rows[:], {}
}

content_get_send_now_batch_sqlite :: proc(ctx: rawptr, batch_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error) {
    impl := cast(^Content_Repo_SQLite)ctx
    q := "SELECT " + ACP_SEND_NOW_BATCH_COLUMNS + " FROM acp_send_now_batches WHERE batch_id=?;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed send now lookup")
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, batch_id)
    rc := sqlite3_step(stmt)
    if rc == SQLITE_DONE do return {}, false, {}
    if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed send now lookup")
    return acp_send_now_batch_from_stmt(stmt), true, {}
}

content_find_send_now_batch_sqlite :: proc(ctx: rawptr, conversation_id, request_id: string) -> (domain.ACP_Send_Now_Batch, bool, domain.Domain_Error) {
    impl := cast(^Content_Repo_SQLite)ctx
    q := "SELECT " + ACP_SEND_NOW_BATCH_COLUMNS + " FROM acp_send_now_batches WHERE conversation_id=? AND request_id=?;"
    if request_id == "" do q = "SELECT " + ACP_SEND_NOW_BATCH_COLUMNS + " FROM acp_send_now_batches WHERE conversation_id=? ORDER BY created_at DESC, rowid DESC LIMIT 1;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed send now lookup")
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, conversation_id)
    if request_id != "" do bind_text(stmt, 2, request_id)
    rc := sqlite3_step(stmt)
    if rc == SQLITE_DONE do return {}, false, {}
    if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed send now lookup")
    return acp_send_now_batch_from_stmt(stmt), true, {}
}

content_save_send_now_batch_sqlite :: proc(ctx: rawptr, row: domain.ACP_Send_Now_Batch) -> domain.Domain_Error {
    guard := tx_repository_enter()
    defer tx_repository_leave(guard)
    impl := cast(^Content_Repo_SQLite)ctx
    q := "INSERT INTO acp_send_now_batches(" + ACP_SEND_NOW_BATCH_COLUMNS + ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) " +
        "ON CONFLICT(batch_id) DO UPDATE SET attempt=excluded.attempt,state=excluded.state,error=excluded.error," +
        "member_ids_json=excluded.member_ids_json,excluded_json=excluded.excluded_json,updated_at=excluded.updated_at;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed send now save")
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,row.batch_id); bind_text(stmt,2,row.owner_user_id); bind_text(stmt,3,row.conversation_id); bind_text(stmt,4,row.agent_instance_id)
    bind_text(stmt,5,row.launch_epoch); bind_text(stmt,6,row.request_id); sqlite3_bind_int64(stmt,7,row.attempt); bind_text(stmt,8,row.state)
    bind_text(stmt,9,row.error); bind_text(stmt,10,row.member_ids_json if row.member_ids_json != "" else "[]"); bind_text(stmt,11,row.excluded_json if row.excluded_json != "" else "[]")
    bind_text(stmt,12,row.created_at); bind_text(stmt,13,row.updated_at)
    if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "send now batch could not be saved")
    return {}
}

content_get_input_runtime_sqlite :: proc(ctx: rawptr, instance: string) -> (domain.ACP_Input_Runtime, bool, domain.Domain_Error) {
    impl := cast(^Content_Repo_SQLite)ctx
    q := "SELECT launch_epoch,steering_supported,updated_at FROM acp_input_runtime WHERE agent_instance_id=?;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return {}, false, domain.domain_error(.Internal_Error, "failed input runtime lookup")
    defer sqlite3_finalize(stmt)
    bind_text(stmt, 1, instance)
    rc := sqlite3_step(stmt)
    if rc == SQLITE_DONE do return {}, false, {}
    if rc != SQLITE_ROW do return {}, false, domain.domain_error(.Internal_Error, "failed input runtime lookup")
    return {agent_instance_id=instance, launch_epoch=column_text(stmt,0), steering_supported=sqlite3_column_int64(stmt,1)!=0, updated_at=column_text(stmt,2)}, true, {}
}

content_save_input_runtime_sqlite :: proc(ctx: rawptr, row: domain.ACP_Input_Runtime) -> domain.Domain_Error {
    guard := tx_repository_enter()
    defer tx_repository_leave(guard)
    impl := cast(^Content_Repo_SQLite)ctx
    q := "INSERT INTO acp_input_runtime(agent_instance_id,launch_epoch,steering_supported,updated_at) VALUES(?,?,?,?) ON CONFLICT(agent_instance_id) DO UPDATE SET launch_epoch=excluded.launch_epoch,steering_supported=excluded.steering_supported,updated_at=excluded.updated_at;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed input runtime save")
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,row.agent_instance_id); bind_text(stmt,2,row.launch_epoch); sqlite3_bind_int64(stmt,3,1 if row.steering_supported else 0); bind_text(stmt,4,row.updated_at)
    if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Conflict, "input runtime could not be saved")
    return {}
}

content_set_message_delivery_flags_sqlite :: proc(ctx: rawptr, message_id, delivered_at: string, clear_read: bool) -> domain.Domain_Error {
    guard := tx_repository_enter()
    defer tx_repository_leave(guard)
    impl := cast(^Content_Repo_SQLite)ctx
    q := "UPDATE chat_messages SET delivered_at=CASE WHEN ?<>'' AND delivered_at='' THEN ? ELSE delivered_at END, read_at=CASE WHEN ? THEN '' ELSE read_at END WHERE message_id=?;"
    stmt: sqlite3_stmt
    if sqlite3_prepare_v2(impl.conn.db, cstring(raw_data(q)), -1, &stmt, nil) != SQLITE_OK do return domain.domain_error(.Internal_Error, "failed message delivery update")
    defer sqlite3_finalize(stmt)
    bind_text(stmt,1,delivered_at); bind_text(stmt,2,delivered_at); sqlite3_bind_int64(stmt,3,1 if clear_read else 0); bind_text(stmt,4,message_id)
    if sqlite3_step(stmt) != SQLITE_DONE do return domain.domain_error(.Internal_Error, "failed message delivery update")
    return {}
}
