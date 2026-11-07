#+feature dynamic-literals
package owner_local

import "core:strings"
import "core:testing"

// V29 removes the owner-local attempt budget (user decision, 2026-11-07). An
// existing V28 database with budget rows upgrades, drops the budget tables and
// releases or restores every control the budget overlay owned.
@(test)
migration_029_drops_budget_tables_and_releases_overlay_blocks :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f);control_destination_seed(t,f)
    before,_:=query(f.store.db,"SELECT task_id,revision FROM tasks WHERE chain_id='chain' AND task_id IN('task','dest') ORDER BY task_id")
    if !testing.expect_value(t,len(before),2) do return
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    // Recreate the exact V16 budget schema that V29 removes.
    v16:=string(MIGRATION_016)
    baselines:=v16[strings.index(v16,"CREATE TABLE native_budget_baselines"):strings.index(v16,"CREATE TABLE local_dependency_retirements")]
    overlap:=v16[strings.index(v16,"CREATE TABLE native_budget_overlap"):]
    testing.expect(t,exec(db,baselines))
    testing.expect(t,exec(db,overlap))
    testing.expect(t,exec(db,`
      INSERT INTO native_budget_baselines SELECT 'chain','task','source','digest',1,seq,'1','1','standalone','{}',seq FROM local_events ORDER BY seq DESC LIMIT 1;
      INSERT INTO native_budget_overlap SELECT 'chain','task',seq,'native_event','1','1' FROM local_events ORDER BY seq DESC LIMIT 1;
      INSERT INTO local_budget_evidence SELECT 'chain','task',seq,'{"reason":"budget_exhausted"}' FROM local_events ORDER BY seq DESC LIMIT 1;
      INSERT INTO local_controls VALUES('chain','task','blocked','ready','budget_exhausted','human');
      INSERT INTO budget_control_owners VALUES('chain','task','budget_exhausted','[]');
      INSERT INTO local_controls VALUES('chain','dest','blocked','ready','native_blocked','human');
      INSERT INTO budget_control_owners VALUES('chain','dest','native_blocked','[["held","ready","operator hold",""]]');
      UPDATE schema_migrations SET version=28;`))
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    rows,_:=query(f.store.db,`SELECT schema_version,(SELECT version FROM schema_migrations),
      (SELECT count(*) FROM sqlite_master WHERE name IN('native_budget_baselines','native_budget_overlap','local_budget_evidence','budget_control_owners','native_budget_snapshot_sealed'))
      FROM runtime_database`)
    testing.expect_value(t,encode(rows),encode([1][3]string{{"29","29","0"}}))
    // The overlay without a saved control is cleared; a saved control is restored.
    controls,_:=query(f.store.db,"SELECT task_id,mode,resume_state,reason,waiting_on FROM local_controls ORDER BY task_id")
    testing.expect_value(t,encode(controls),encode([1][5]string{{"dest","held","ready","operator hold",""}}))
    after,_:=query(f.store.db,"SELECT task_id,revision FROM tasks WHERE chain_id='chain' AND task_id IN('task','dest') ORDER BY task_id")
    for row,i in after do testing.expect_value(t,number(row[1]),number(before[i][1])+1)
    testing.expect(t,control_ready(&f.store,"chain","task"),"the budget-blocked task is released")
    // The released task admits ordinary work again.
    revision:=after[1][1]
    child:=lease_child()
    testing.expect_value(t,lease_invoke(f,lease_request(f,child,"lease.claim","claim_after_v29","lease","",revision),"",child).code,"ok")
    // Importing a previously activated native snapshot is no longer sealed.
    sealed,_:=query(f.store.db,"SELECT count(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='native_history_records' AND sql LIKE '%budget%'")
    testing.expect_value(t,sealed[0][0],"0")
}

// R2 review: V29 must not clear a block that no budget owner row claims. A
// genuine worker lease.block may carry a free-text reason equal to a former
// budget word; it stays blocked through the upgrade.
@(test)
migration_029_keeps_unowned_block_with_budget_word_reason :: proc(t:^testing.T) {
    saved:=context.allocator;context.allocator=context.temp_allocator;defer {context.allocator=saved}
    f:=fixture(t);defer destroy(f);lifecycle_seed(t,f)
    close(&f.store)
    db:DB
    testing.expect_value(t,sqlite3_open(strings.clone_to_cstring(f.path,context.temp_allocator),&db),0)
    testing.expect(t,exec(db,`
      INSERT INTO local_controls VALUES('chain','task','blocked','ready','budget_exhausted','human');
      UPDATE schema_migrations SET version=28;`))
    before,_:=query(db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id='task'")
    testing.expect_value(t,sqlite3_close(db),0)
    if !testing.expect(t,open(&f.store,f.path,"account","bridge","bridge_key")) do return
    controls,_:=query(f.store.db,"SELECT task_id,mode,resume_state,reason,waiting_on FROM local_controls ORDER BY task_id")
    testing.expect_value(t,encode(controls),encode([1][5]string{{"task","blocked","ready","budget_exhausted","human"}}))
    after,_:=query(f.store.db,"SELECT revision FROM tasks WHERE chain_id='chain' AND task_id='task'")
    testing.expect_value(t,encode(after),encode(before))
    testing.expect(t,!control_ready(&f.store,"chain","task"),"the genuine block survives V29")
}
