package sqlite

import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// EV2: subscriptions belong to an agent instance (REQ-EVP-1..3).

instance_sub_scalar :: proc(conn: ^Conn, query: string) -> i64 {
	stmt: sqlite3_stmt
	q := fmt.ctprintf("%s", query)
	if sqlite3_prepare_v2(conn.db, q, -1, &stmt, nil) != SQLITE_OK do return -1
	defer sqlite3_finalize(stmt)
	if sqlite3_step(stmt) != SQLITE_ROW do return -1
	return sqlite3_column_int64(stmt, 0)
}

instance_sub_list :: proc(t: ^testing.T, repo: iface.Event_Subscription_Repository, instance: string) -> (count: int, chain, task: string) {
	rows, err := repo.list(repo.ctx, "alice", instance)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	count = len(rows)
	if count > 0 {chain = fmt.tprintf("%s", rows[0].chain_id); task = fmt.tprintf("%s", rows[0].task_id)}
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
	return
}

instance_sub_add_instance :: proc(conn: ^Conn, instance, agent: string) -> bool {
	return exec(
		conn,
		fmt.tprintf(
			"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,created_at,updated_at) VALUES('%s','alice','%s','bridge','idle','now','now');",
			instance,
			agent,
		),
	)
}

@(test)
test_event_subscriptions_belong_to_instances :: proc(t: ^testing.T) {
	instance_ownership_scenario(t)
}
instance_ownership_scenario :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: Event_Subscription_Repo_SQLite
	repo := new_event_subscription_repository(&impl, &conn)
	repos := iface.Repositories {
		event_subscriptions = repo,
	}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	defer iface.unit_of_work_rollback(&uow)
	// One durable agent (agt_coord) coordinates two chains through two instances.
	testing.expect(t, instance_sub_add_instance(&conn, "inst_a", "agt_coord"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_b", "agt_coord"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_c", "agt_coord"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_w1", "agt_worker"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_w2", "agt_worker"))
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain_a','inst_a','agt_coord','alice','coordinator','now'),('chain_b','inst_b','agt_coord','alice','coordinator','now');",
		),
	)
	n, chain, _ := instance_sub_list(t, repo, "inst_a")
	testing.expect_value(t, n, 1); testing.expect_value(t, chain, "chain_a")
	n, chain, _ = instance_sub_list(t, repo, "inst_b")
	testing.expect_value(t, n, 1); testing.expect_value(t, chain, "chain_b")
	testing.expect_value(
		t,
		instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscriber_agent_id='agt_coord';"),
		i64(2),
	)

	// Coordinator reassignment moves the chain's role default to the new holder.
	testing.expect(t, exec(&conn, "UPDATE task_chain_members SET role='worker' WHERE chain_id='chain_a' AND agent_instance_id='inst_a';"))
	testing.expect(t, exec(&conn, "INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain_a','inst_c','agt_coord','alice','coordinator','now');"))
	n, _, _ = instance_sub_list(t, repo, "inst_a")
	testing.expect_value(t, n, 0)
	n, chain, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 1); testing.expect_value(t, chain, "chain_a")

	// A work claim's default belongs to the holder; transfer moves it.
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('lease','task','chain_b','alice',1,'inst_w1','work','now','','','wake');",
		),
	)
	task: string
	n, _, task = instance_sub_list(t, repo, "inst_w1")
	testing.expect_value(t, n, 1); testing.expect_value(t, task, "task")
	testing.expect(t, exec(&conn, "UPDATE task_leases SET holder_instance_id='inst_w2' WHERE lease_id='lease';"))
	n, _, _ = instance_sub_list(t, repo, "inst_w1")
	testing.expect_value(t, n, 0)
	n, _, task = instance_sub_list(t, repo, "inst_w2")
	testing.expect_value(t, n, 1); testing.expect_value(t, task, "task")

	// An explicit watch belongs to the calling instance only.
	testing.expect_value(
		t,
		repo.put(repo.ctx, {subscription_id = "watch_b", owner_user_id = "alice", subscriber_instance_id = "inst_b", chain_id = "chain_a", source = "explicit", filter_subjects = "[]", wake_policy = "catalog", consumer_name = "watch_b", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscription_id='watch_b' AND subscriber_agent_id='agt_coord';"),
		i64(1),
	)
	testing.expect_value(
		t,
		repo.put(repo.ctx, {subscription_id = "anon", owner_user_id = "alice", chain_id = "chain_a", source = "explicit", filter_subjects = "[]", consumer_name = "anon", created_at = "now"}).code,
		domain.Error_Code.Forbidden,
	)
	exists, _ := repo.exists(repo.ctx, "alice", "inst_a", "watch_b")
	testing.expect(t, !exists, "another instance of the same agent does not see the watch")
	testing.expect_value(
		t,
		repo.delivered(repo.ctx, "alice", "inst_b", {subscription_id = "watch_b", event_id = "ev_1", ack_reply = "r", stream_sequence = 1}).code,
		domain.Error_Code.None,
	)
	testing.expect_value(
		t,
		repo.delivered(repo.ctx, "alice", "inst_a", {subscription_id = "watch_b", event_id = "ev_2", ack_reply = "r", stream_sequence = 2}).code,
		domain.Error_Code.Not_Found,
	)

	// Notice target: only the owning instance (REQ-EVP-4a).
	rows, _ := repo.list(repo.ctx, "alice", "inst_b")
	for row in rows {
		target, terr := repo.notice_target(repo.ctx, row)
		testing.expect_value(t, terr.code, domain.Error_Code.None)
		testing.expect_value(t, target.instance_id, "inst_b")
		domain.event_notice_target_destroy(&target)
	}
	subscription_rows_free(rows)

	// User stop (E3): every subscription of the instance ends, with its
	// deliveries, and each consumer is queued for deletion.
	testing.expect(t, exec(&conn, "DELETE FROM event_consumer_deletions;"))
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='stopped',stopped_by='user' WHERE agent_instance_id='inst_b';"))
	n, _, _ = instance_sub_list(t, repo, "inst_b")
	testing.expect_value(t, n, 0)
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_deliveries WHERE subscription_id='watch_b';"), i64(0))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions;"), i64(2))
	n, _, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 1)
	// The stopped instance keeps holding no subscription while membership changes.
	testing.expect(t, exec(&conn, "UPDATE task_chain_members SET created_at='later' WHERE chain_id='chain_b';"))
	n, _, _ = instance_sub_list(t, repo, "inst_b")
	testing.expect_value(t, n, 0)
	// A notice target for a removed row is empty: no fallback to a sibling.
	gone := domain.Event_Subscription{subscription_id = "watch_b", owner_user_id = "alice", subscriber_instance_id = "inst_b"}
	target, _ := repo.notice_target(repo.ctx, gone)
	testing.expect_value(t, target.instance_id, "")
	domain.event_notice_target_destroy(&target)

	// An explicit start clears the stop: fresh role defaults, no explicit watch.
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='running',stopped_by='' WHERE agent_instance_id='inst_b';"))
	n, chain, _ = instance_sub_list(t, repo, "inst_b")
	testing.expect_value(t, n, 1); testing.expect_value(t, chain, "chain_b")
	testing.expect_value(
		t,
		instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscription_id='watch_b';"),
		i64(0),
	)

	// An idle stop (no user stop) keeps subscriptions so an event can wake it.
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='stopped' WHERE agent_instance_id='inst_c';"))
	n, _, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 1)
	// A user-stopped claim holder loses its claim default (replacement path).
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET stopped_by='user' WHERE agent_instance_id='inst_w2';"))
	n, _, _ = instance_sub_list(t, repo, "inst_w2")
	testing.expect_value(t, n, 0)

	// A crash or termination alone ends nothing: coordinator wake and bot
	// relaunch restart the SAME instance, which must still get the events
	// published while it was down.
	testing.expect_value(
		t,
		repo.put(repo.ctx, {subscription_id = "watch_c", owner_user_id = "alice", subscriber_instance_id = "inst_c", chain_id = "chain_b", source = "explicit", filter_subjects = "[]", wake_policy = "catalog", consumer_name = "watch_c", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	testing.expect(t, exec(&conn, "DELETE FROM event_consumer_deletions;"))
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='failed',last_error_json='{\"class\":\"retriable\"}' WHERE agent_instance_id='inst_c';"))
	n, _, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 2)
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET last_error_json='' WHERE agent_instance_id='inst_c';"))
	n, _, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 2) // untyped failure (Dead) while still coordinator
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='running' WHERE agent_instance_id='inst_c';"))
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='terminated' WHERE agent_instance_id='inst_c';"))
	n, _, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 2) // relaunched, then terminated: still the role holder
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions;"), i64(0))
	// Superseded: the coordinator role moves off the Dead instance, so its
	// explicit watch ends with its role default; consumers are queued.
	testing.expect(t, exec(&conn, "UPDATE task_chain_members SET role='worker' WHERE chain_id='chain_a' AND agent_instance_id='inst_c';"))
	n, _, _ = instance_sub_list(t, repo, "inst_c")
	testing.expect_value(t, n, 0)
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions;"), i64(2))
	// A live instance that loses a role keeps its explicit watch.
	testing.expect_value(
		t,
		repo.put(repo.ctx, {subscription_id = "watch_w1", owner_user_id = "alice", subscriber_instance_id = "inst_w1", chain_id = "chain_b", source = "explicit", filter_subjects = "[]", wake_policy = "catalog", consumer_name = "watch_w1", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	n, _, _ = instance_sub_list(t, repo, "inst_w1")
	testing.expect_value(t, n, 1)
	// Superseded the other way round: the instance dies after its roles moved
	// (inst_w1's claim went to inst_w2 above).
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='terminated' WHERE agent_instance_id='inst_w1';"))
	n, _, _ = instance_sub_list(t, repo, "inst_w1")
	testing.expect_value(t, n, 0)
	// A claim transfer away from a Dead holder ends its subscriptions too.
	testing.expect(t, instance_sub_add_instance(&conn, "inst_w3", "agt_worker"))
	testing.expect(t, exec(&conn, "INSERT INTO task_leases(lease_id,task_id,chain_id,owner_user_id,attempt_no,holder_instance_id,kind,granted_at,expires_at,hard_deadline_at,delivery) VALUES('lease3','task3','chain_b','alice',1,'inst_w3','work','now','','','wake');"))
	testing.expect_value(
		t,
		repo.put(repo.ctx, {subscription_id = "watch_w3", owner_user_id = "alice", subscriber_instance_id = "inst_w3", chain_id = "chain_b", source = "explicit", filter_subjects = "[]", wake_policy = "catalog", consumer_name = "watch_w3", created_at = "now"}).code,
		domain.Error_Code.None,
	)
	testing.expect(t, exec(&conn, "UPDATE agent_instances SET runtime_status='failed' WHERE agent_instance_id='inst_w3';"))
	n, _, _ = instance_sub_list(t, repo, "inst_w3")
	testing.expect_value(t, n, 2) // crashed, still holds its claim
	testing.expect(t, exec(&conn, "UPDATE task_leases SET holder_instance_id='inst_w1' WHERE lease_id='lease3';"))
	n, _, _ = instance_sub_list(t, repo, "inst_w3")
	testing.expect_value(t, n, 0)
}

// REQ-EVP-3 (rolling restart / rollback): a row an older build writes without
// an instance is deleted by the next sweep, and its consumer is queued.
@(test)
test_event_subscription_prune_deletes_rows_without_instance :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: Event_Subscription_Repo_SQLite
	repo := new_event_subscription_repository(&impl, &conn)
	repos := iface.Repositories {
		event_subscriptions = repo,
	}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl, &conn, &repos)
	// The previous build's INSERT does not name subscriber_instance_id.
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,source,filter_subjects,wake_policy,consumer_name,created_at) VALUES('old_build','alice','agt','chain','explicit','[]','catalog','old_build','now');",
		),
	)
	testing.expect(t, exec(&conn, "INSERT INTO event_deliveries(subscription_id,event_id,ack_reply,stream_sequence) VALUES('old_build','ev','r',1);"))
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t, began) do return
	testing.expect_value(t, repo.put(repo.ctx, {subscription_id = "kept", owner_user_id = "alice", subscriber_instance_id = "inst", chain_id = "chain", source = "explicit", filter_subjects = "[]", wake_policy = "catalog", consumer_name = "kept", created_at = "now"}).code, domain.Error_Code.None)
	testing.expect_value(t, repo.prune(repo.ctx, "2000-01-01T00:00:00Z").code, domain.Error_Code.None)
	committed, _ := iface.unit_of_work_commit(&uow)
	testing.expect(t, committed)
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions;"), i64(1))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscription_id='kept';"), i64(1))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_deliveries;"), i64(0))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions WHERE consumer_name='old_build';"), i64(1))
}

subscription_rows_free :: proc(rows: []domain.Event_Subscription) {
	for &row in rows do domain.event_subscription_destroy(&row)
	delete(rows)
}

@(test)
test_event_subscription_bot_replacement_ends_old_instance :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	testing.expect(t, instance_sub_add_instance(&conn, "inst_bot_old", "agt_bot"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_bot_new", "agt_bot"))
	testing.expect(t, exec(&conn, "INSERT INTO bots(bot_id,owner_user_id,agent_id,agent_instance_id,created_at,updated_at) VALUES('bot','alice','agt_bot','inst_bot_old','now','now');"))
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,subscriber_instance_id,chain_id,source,filter_subjects,wake_policy,consumer_name,created_at) VALUES('w','alice','agt_bot','inst_bot_old','chain','explicit','[]','catalog','w','now');",
		),
	)
	testing.expect(t, exec(&conn, "UPDATE bots SET agent_instance_id='inst_bot_new' WHERE bot_id='bot';"))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions;"), i64(0))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions WHERE consumer_name='w';"), i64(1))
}

// REQ-EVP-3: the migration removes identity-keyed rows and queues their
// consumers, keeps a bot's watches on its canonical instance, derives role
// defaults per instance, and is safe to run again.
@(test)
test_event_subscription_instance_migration_cleans_legacy_rows :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	ok, _ := run_migrations(&conn, stop_before = "events_006_instance_subscriptions.sql")
	if !testing.expect(t, ok) do return
	testing.expect(t, instance_sub_add_instance(&conn, "inst_coord", "agt_coord"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_old", "agt_coord"))
	testing.expect(t, instance_sub_add_instance(&conn, "inst_bot", "agt_bot"))
	// bob's bot instance was stopped by the user: its legacy watch is deleted.
	testing.expect(t, exec(&conn, "INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,runtime_status,stopped_by,created_at,updated_at) VALUES('inst_gone_bot','bob','agt_gone_bot','bridge','stopped','user','now','now');"))
	testing.expect(t, exec(&conn, "INSERT INTO bots(bot_id,owner_user_id,agent_id,agent_instance_id,created_at,updated_at) VALUES('bot','alice','agt_bot','inst_bot','now','now'),('bot2','bob','agt_gone_bot','inst_gone_bot','now','now');"))
	// Legacy triggers create an identity-keyed role default for the membership.
	testing.expect(t, exec(&conn, "INSERT INTO task_chain_members(chain_id,agent_instance_id,agent_id,owner_user_id,role,created_at) VALUES('chain','inst_coord','agt_coord','alice','coordinator','now');"))
	testing.expect(
		t,
		exec(
			&conn,
			"INSERT INTO event_subscriptions(subscription_id,owner_user_id,subscriber_agent_id,chain_id,source,filter_subjects,wake_policy,consumer_name,created_at) VALUES('legacy_watch','alice','agt_coord','other','explicit','[]','catalog','legacy_watch','now'),('bot_watch','alice','agt_bot','chain','explicit','[]','catalog','bot_watch','now'),('gone_watch','bob','agt_gone_bot','chain','explicit','[]','catalog','gone_watch','now');",
		),
	)
	testing.expect(t, exec(&conn, "INSERT INTO event_deliveries(subscription_id,event_id,ack_reply,stream_sequence) VALUES('legacy_watch','ev','r',1),('bot_watch','ev','r',1);"))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions;"), i64(4))
	testing.expect(t, exec(&conn, "DELETE FROM event_consumer_deletions;"))

	ok, _ = run_migrations(&conn)
	if !testing.expect(t, ok) do return
	ok, _ = run_migrations(&conn)
	testing.expect(t, ok, "migration is idempotent")

	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscriber_instance_id='';"), i64(0))
	// The legacy role default, legacy_watch and gone_watch are deleted; the
	// moved bot watch's old consumer (which read from the start of the stream)
	// is released too. All four consumers are queued for deletion.
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions;"), i64(4))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_consumer_deletions WHERE consumer_name IN ('legacy_watch','gone_watch','bot_watch');"), i64(3))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_deliveries WHERE subscription_id='legacy_watch';"), i64(0))
	// The bot keeps its watch on its instance, with a new consumer that starts
	// at the migration (millisecond created_at), and no old deliveries.
	testing.expect_value(
		t,
		instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscription_id='bot_watch' AND subscriber_instance_id='inst_bot' AND consumer_name LIKE 'inbox_%' AND created_at LIKE '____-__-__T__:__:__.___Z';"),
		i64(1),
	)
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_deliveries WHERE subscription_id='bot_watch';"), i64(0))
	testing.expect_value(
		t,
		instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE source='role_default' AND created_at LIKE '____-__-__T__:__:__.___Z';"),
		i64(1),
	)
	testing.expect_value(
		t,
		instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE source='role_default' AND subscriber_instance_id='inst_coord' AND chain_id='chain';"),
		i64(1),
	)
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions WHERE subscriber_instance_id='inst_old';"), i64(0))
	testing.expect_value(t, instance_sub_scalar(&conn, "SELECT COUNT(*) FROM event_subscriptions;"), i64(2))
}

@(test)
test_event_notice_snapshot_matches_scoped_targets_and_receipt_clocks :: proc(t: ^testing.T) {
	conn, opened, _ := open(":memory:")
	if !testing.expect(t, opened) do return
	defer close(&conn)
	migrated, _ := run_migrations(&conn)
	if !testing.expect(t, migrated) do return
	impl: Event_Subscription_Repo_SQLite
	repo := new_event_subscription_repository(&impl, &conn)
	repos := iface.Repositories{event_subscriptions=repo}
	factory_impl: SQLite_Unit_Of_Work_Factory
	factory := new_unit_of_work_factory(&factory_impl,&conn,&repos)
	_, outside_err := repo.notice_snapshot(repo.ctx)
	testing.expect_value(t,outside_err.code,domain.Error_Code.Internal_Error)
	uow, began, _ := iface.unit_of_work_begin(&factory)
	if !testing.expect(t,began) do return
	defer iface.unit_of_work_rollback(&uow)
	testing.expect(t,instance_sub_add_instance(&conn,"inst_a","shared_agent"))
	testing.expect(t,instance_sub_add_instance(&conn,"inst_b","shared_agent"))
	testing.expect(t,exec(&conn,"INSERT INTO bots(bot_id,owner_user_id,agent_id,agent_instance_id,created_at,updated_at) VALUES('bot','alice','shared_agent','inst_b','now','now');"))
	for spec in ([][3]string{
		{"a","alice","inst_a"},{"b","alice","inst_b"},
		{"foreign","bob","inst_a"},{"missing","alice","missing"},
	}) {
		testing.expect_value(t,repo.put(repo.ctx,{
			subscription_id=spec[0],owner_user_id=spec[1],subscriber_instance_id=spec[2],
			chain_id=spec[0],source="explicit",filter_subjects="[]",consumer_name=spec[0],created_at="now",
		}).code,domain.Error_Code.None)
	}
	for id in ([]string{"first","second","acked"}) {
		testing.expect_value(t,repo.delivered(repo.ctx,"alice","inst_a",{
			subscription_id="a",event_id=id,ack_reply=id,
		}).code,domain.Error_Code.None)
	}
	testing.expect(t,exec(&conn,"UPDATE event_deliveries SET recorded_at='2026-01-02T00:00:00Z'; UPDATE event_deliveries SET recorded_at='2026-01-01T00:00:00Z' WHERE event_id='first'; UPDATE event_deliveries SET acknowledged=1,recorded_at='2000-01-01T00:00:00Z' WHERE event_id='acked';"))
	rows, err := repo.notice_snapshot(repo.ctx)
	testing.expect_value(t,err.code,domain.Error_Code.None)
	defer {for &row in rows do domain.event_notice_snapshot_destroy(&row); delete(rows)}
	testing.expect_value(t,len(rows),4)
	for row in rows {
		switch row.subscription_id {
		case "a":
			testing.expect_value(t,row.target.instance_id,"inst_a")
			testing.expect(t,!row.target.is_bot,"bot status belongs to the instance, not its shared agent")
			testing.expect_value(t,row.outstanding,i64(2))
			testing.expect_value(t,row.oldest_delivery,"2026-01-01T00:00:00Z")
		case "b":
			testing.expect_value(t,row.target.instance_id,"inst_b")
			testing.expect(t,row.target.is_bot)
			testing.expect_value(t,row.outstanding,i64(0))
		case "foreign","missing":
			testing.expect_value(t,row.target.instance_id,"")
			testing.expect(t,!row.target.is_bot)
		}
	}
}
