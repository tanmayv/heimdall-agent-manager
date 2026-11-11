package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:slice"

SCHEMA_VERSION :: 38
MIGRATION_038 :: #load("migration_038.sql")
MIGRATION_037 :: #load("migration_037.sql")
MIGRATION_036 :: #load("migration_036.sql")
MIGRATION_035 :: #load("migration_035.sql")
MIGRATION_034 :: #load("migration_034.sql")
MIGRATION_033 :: #load("migration_033.sql")
MIGRATION_032 :: #load("migration_032.sql")
MIGRATION_031 :: #load("migration_031.sql")
MIGRATION_030 :: #load("migration_030.sql")
MIGRATION_029 :: #load("migration_029.sql")
MIGRATION_028 :: #load("migration_028.sql")
MIGRATION_027 :: #load("migration_027.sql")
MIGRATION_026 :: #load("migration_026.sql")
MIGRATION_025 :: #load("migration_025.sql")
MIGRATION_024 :: #load("migration_024.sql")
MIGRATION_023 :: #load("migration_023.sql")
MIGRATION_022 :: #load("migration_022.sql")
MIGRATION_021 :: #load("migration_021.sql")
MIGRATION_020 :: #load("migration_020.sql")
MIGRATION_019 :: #load("migration_019.sql")
MIGRATION_018 :: #load("migration_018.sql")
MIGRATION_017 :: #load("migration_017.sql")
MIGRATION_016 :: #load("migration_016.sql")
MIGRATION_015 :: #load("migration_015.sql")
MIGRATION_014 :: #load("migration_014.sql")
MIGRATION_013 :: #load("migration_013.sql")
MIGRATION_012 :: #load("migration_012.sql")
MIGRATION_011 :: #load("migration_011.sql")
MIGRATION_010 :: #load("migration_010.sql")
MIGRATION_009 :: #load("migration_009.sql")
MIGRATION_008 :: #load("migration_008.sql")
MIGRATION_007 :: #load("migration_007.sql")
MIGRATION_006 :: #load("migration_006.sql")
MIGRATION_005 :: #load("migration_005.sql")
MIGRATION_004 :: #load("migration_004.sql")
MIGRATION_003 :: #load("migration_003.sql")
MIGRATION_002 :: #load("migration_002.sql")

// Called only while the lifetime writer lock is held, before exposing Store.
// SQLite PRAGMAs that cannot change in a transaction precede all schema writes.
migrate :: proc(db:DB) -> bool {
    if !exec(db,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;") do return false
    if !exec(db,"BEGIN IMMEDIATE") do return false
    committed:=false
    defer { if !committed do _=exec(db,"ROLLBACK") }
    if !exec(db,"CREATE TABLE IF NOT EXISTS schema_migrations(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL CHECK(version>0))") do return false
    rows,ok:=query(db,"SELECT version FROM schema_migrations WHERE singleton=1")
    if !ok do return false
    version:i64
    if len(rows)>0 do version=number(rows[0][0])
    if version>SCHEMA_VERSION do return false
    if version==0 {
        if !exec(db,string(SCHEMA)) do return false
        if !exec(db,"INSERT INTO schema_migrations VALUES(1,1)") do return false
        version=1
    }
    if version==1 {
        if !exec(db,string(MIGRATION_002)) do return false
        orphans,checked:=query(db,"SELECT intent_id FROM runtime_intents WHERE principal_id='' LIMIT 1")
        if !checked || len(orphans)>0 do return false
        // Backfill exact digests before installing the immutable intent trigger.
        // The SQL migration deliberately leaves existing V1 payload bytes intact.
        rows,ok=query(db,"SELECT intent_id,payload_json FROM runtime_intents")
        if !ok do return false
        for row in rows {
            if _,ok=query(db,"UPDATE runtime_intents SET payload_digest=? WHERE intent_id=?",payload_hash(row[1]),row[0]);!ok do return false
        }
        if !exec(db,INTENT_IDENTITY_TRIGGER) do return false
        if !exec(db,"CREATE TRIGGER intent_settled_immutable BEFORE UPDATE ON runtime_intents WHEN OLD.state='settled' BEGIN SELECT RAISE(ABORT,'settled intent'); END;") do return false
        if _,ok=query(db,"UPDATE schema_migrations SET version=? WHERE singleton=1","2");!ok do return false
    }
    if version<=2 {
        if !exec(db,string(MIGRATION_003)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=3 WHERE singleton=1") do return false
    }
    if version<=3 {
        if !exec(db,string(MIGRATION_004)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=4 WHERE singleton=1") do return false
    }
    if version<=4 {
        if !exec(db,string(MIGRATION_005)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=5 WHERE singleton=1") do return false
    }
    if version<=5 {
        if !exec(db,string(MIGRATION_006)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=6 WHERE singleton=1") do return false
    }
    if version<=6 {
        if !exec(db,string(MIGRATION_007)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=7 WHERE singleton=1") do return false
    }
    if version<=7 {
        if !exec(db,string(MIGRATION_008)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=8 WHERE singleton=1") do return false
    }
    if version<=8 {
        if !exec(db,string(MIGRATION_009)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=9 WHERE singleton=1") do return false
    }
    if version<=9 {
        if !exec(db,string(MIGRATION_010)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=10 WHERE singleton=1") do return false
    }
    if version<=10 {
        if !exec(db,string(MIGRATION_011)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=11 WHERE singleton=1") do return false
    }
    if version<=11 {
        if !exec(db,string(MIGRATION_012)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=12 WHERE singleton=1") do return false
    }
    if version<=12 {
        if !exec(db,string(MIGRATION_013)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=13 WHERE singleton=1") do return false
    }
    if version<=13 {
        if !exec(db,string(MIGRATION_014)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=14 WHERE singleton=1") do return false
    }
    if version<=14 {
        if !exec(db,string(MIGRATION_015)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=15 WHERE singleton=1") do return false
    }
    if version<=15 {
        if !exec(db,string(MIGRATION_016)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=16 WHERE singleton=1") do return false
    }
    if version<=16 {
        if !exec(db,string(MIGRATION_017)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=17 WHERE singleton=1") do return false
    }
    if version<=17 {
        if !exec(db,string(MIGRATION_018)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=18 WHERE singleton=1") do return false
    }
    if version<=18 {
        if !exec(db,string(MIGRATION_019)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=19 WHERE singleton=1") do return false
    }
    if version<=19 {
        if !exec(db,string(MIGRATION_020)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=20 WHERE singleton=1") do return false
    }
    if version<=20 {
        if !exec(db,string(MIGRATION_021)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=21 WHERE singleton=1") do return false
    }
    if version<=21 {
        if !exec(db,string(MIGRATION_022)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=22 WHERE singleton=1") do return false
    }
    if version<=22 {
        if !exec(db,string(MIGRATION_023)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=23 WHERE singleton=1") do return false
    }
    if version<=23 {
        if !exec(db,string(MIGRATION_024)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=24 WHERE singleton=1") do return false
    }
    if version<=24 {
        if !exec(db,string(MIGRATION_025)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=25 WHERE singleton=1") do return false
    }
    if version<=25 {
        if !exec(db,string(MIGRATION_026)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=26 WHERE singleton=1") do return false
    }
    if version<=26 {
        if !exec(db,string(MIGRATION_027)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=27 WHERE singleton=1") do return false
    }
    if version<=27 {
        if !exec(db,string(MIGRATION_028)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=28 WHERE singleton=1") do return false
    }
    if version<=28 {
        if !migration_029_release_budget_controls(db) do return false
        if !exec(db,string(MIGRATION_029)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=29 WHERE singleton=1") do return false
    }
    if version<=29 {
        // Re-runnable: the column may survive a test downgrade of the version.
        columns,read:=query(db,"SELECT 1 FROM pragma_table_info('chain_genesis') WHERE name='import_manifest_hash'")
        if !read do return false
        if len(columns)==0 && !exec(db,"ALTER TABLE chain_genesis ADD COLUMN import_manifest_hash TEXT NOT NULL DEFAULT ''") do return false
        if !exec(db,string(MIGRATION_030)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=30 WHERE singleton=1") do return false
    }
    if version<=30 {
        columns,read:=query(db,"SELECT 1 FROM pragma_table_info('task_comments') WHERE name='created_at'")
        if !read do return false
        if len(columns)==0 && !exec(db,"ALTER TABLE task_comments ADD COLUMN created_at TEXT NOT NULL DEFAULT ''") do return false
        if !exec(db,string(MIGRATION_031)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=31 WHERE singleton=1") do return false
    }
    if version<=31 {
        if !exec(db,string(MIGRATION_032)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=32 WHERE singleton=1") do return false
    }
    if version<=32 {
        if !exec(db,string(MIGRATION_033)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=33 WHERE singleton=1") do return false
    }
    if version<=33 {
        if !exec(db,string(MIGRATION_034)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=34 WHERE singleton=1") do return false
    }
    if version<=34 {
        // Re-runnable: the column may survive a test downgrade of the version.
        columns,read:=query(db,"SELECT 1 FROM pragma_table_info('local_reviews') WHERE name='principal_kind'")
        if !read do return false
        if len(columns)==0 && !exec(db,"ALTER TABLE local_reviews ADD COLUMN principal_kind TEXT NOT NULL DEFAULT 'agent' CHECK(principal_kind IN('device','agent'))") do return false
        if !exec(db,string(MIGRATION_035)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=35 WHERE singleton=1") do return false
    }
    if version<=35 {
        if !exec(db,string(MIGRATION_036)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=36 WHERE singleton=1") do return false
    }
    if version<=36 {
        if !exec(db,string(MIGRATION_037)) do return false
        if !migration_037_review_roles(db) do return false
        if !exec(db,"UPDATE schema_migrations SET version=37 WHERE singleton=1") do return false
    }
    if version<=37 {
        if !exec(db,string(MIGRATION_038)) do return false
        if !exec(db,"UPDATE schema_migrations SET version=38 WHERE singleton=1") do return false
    }
    if !exec(db,"COMMIT") do return false
    committed=true
    return true
}

// V29 removes the owner-local attempt budget. A task blocked only by the budget
// overlay must not stay stuck once that overlay's table is gone: restore the
// independent control the overlay saved (prior_json), or clear the overlay.
// The table may be absent when an older schema never created it.
migration_029_release_budget_controls :: proc(db:DB) -> bool {
    present,ok:=query(db,"SELECT 1 FROM sqlite_master WHERE type='table' AND name='budget_control_owners'")
    if !ok do return false
    if len(present)>0 {
        owners,read:=query(db,"SELECT chain_id,task_id,reason,prior_json FROM budget_control_owners ORDER BY chain_id,task_id")
        if !read do return false
        for owner in owners {
            chain,task,reason:=owner[0],owner[1],owner[2]
            prior:[dynamic][]string
            if json.unmarshal_string(owner[3],&prior,.JSON,context.temp_allocator)!=nil do return false
            if len(prior)>1 || (len(prior)==1 && len(prior[0])!=4) do return false
            controls,found:=query(db,"SELECT mode,reason FROM local_controls WHERE chain_id=? AND task_id=?",chain,task)
            if !found do return false
            if len(controls)!=1 do continue
            if controls[0][0]=="held" {
                // A hold placed over the overlay resumes to the saved control.
                resume,waiting:="ready",""
                if len(prior)==1 { resume=prior[0][0];waiting=prior[0][3];if resume=="held" do resume=prior[0][1] }
                if _,ok=query(db,"UPDATE local_controls SET resume_state=?,waiting_on=? WHERE chain_id=? AND task_id=?",resume,waiting,chain,task);!ok do return false
            } else if controls[0][0]=="blocked" && controls[0][1]==reason {
                if len(prior)==0 {
                    if _,ok=query(db,"DELETE FROM local_controls WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
                } else if _,ok=query(db,"UPDATE local_controls SET mode=?,resume_state=?,reason=?,waiting_on=? WHERE chain_id=? AND task_id=?",prior[0][0],prior[0][1],prior[0][2],prior[0][3],chain,task);!ok do return false
            } else do continue
            if _,ok=query(db,"UPDATE tasks SET revision=revision+1 WHERE chain_id=? AND task_id=?",chain,task);!ok do return false
        }
    }
    // Only owner rows identify overlay blocks. A block without one is a genuine
    // lease.block whose free-text reason may coincide with a budget word, so it
    // is left untouched.
    return true
}

INTENT_IDENTITY_TRIGGER :: `CREATE TRIGGER intent_identity_immutable BEFORE UPDATE ON runtime_intents
WHEN NEW.intent_id IS NOT OLD.intent_id OR NEW.chain_id IS NOT OLD.chain_id OR NEW.commit_seq IS NOT OLD.commit_seq
 OR NEW.principal_id IS NOT OLD.principal_id OR NEW.operation_id IS NOT OLD.operation_id OR NEW.kind IS NOT OLD.kind
 OR NEW.destination_bridge IS NOT OLD.destination_bridge OR NEW.exact_fence_json IS NOT OLD.exact_fence_json
 OR NEW.payload_json IS NOT OLD.payload_json OR NEW.payload_digest IS NOT OLD.payload_digest
BEGIN SELECT RAISE(ABORT,'immutable intent'); END;`

// V37 removes review roles. Every brief that names review_roles is rewritten
// in place: the key is dropped and the agents that held each role at
// migration time join brief.reviewers. A role resolves to the task's latest
// review.roles pairs for that role, else to the chain's current fleet rows
// serving it (unpaused). The task's author and the chain's coordinators are
// never reviewers; a role left without a holder makes the brief require the
// user's approval instead, so no gate is ever lowered. A task with a
// review.roles configuration also gains every configured pair agent (and the
// configuration's user-approval flag) on its latest requirements revision, and
// role verdicts already posted are carried into local_reviews. Workflow
// definitions and pending proposals map roles through the fleet only. Each
// decision is recorded in local_review_role_migrations. Idempotent: rewritten
// briefs no longer name review_roles, merges are set unions and every insert
// ignores duplicates.
MIGRATION_037_TRIGGERS :: `
CREATE TRIGGER IF NOT EXISTS task_requirements_immutable BEFORE UPDATE ON task_requirements BEGIN SELECT RAISE(ABORT,'immutable lifecycle evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_workflow_definitions_immutable BEFORE UPDATE ON local_workflow_definitions BEGIN SELECT RAISE(ABORT,'immutable evidence'); END;
CREATE TRIGGER IF NOT EXISTS local_chain_defaults_no_update BEFORE UPDATE ON local_chain_defaults_versions
BEGIN SELECT RAISE(ABORT,'immutable defaults history'); END;`

Migration_037_Mapping :: struct { role,agent,source:string }

migration_037_record :: proc(db:DB,chain,subject,id,revision:string,m:Migration_037_Mapping) -> bool {
    _,ok:=query(db,"INSERT OR IGNORE INTO local_review_role_migrations VALUES(?,?,?,?,?,?,?)",chain,subject,id,revision,m.role,m.agent,m.source)
    return ok
}
// Agents never made reviewers: the task's author and the chain's coordinators.
migration_037_excluded :: proc(db:DB,chain,task:string) -> ([]string,bool) {
    rows,ok:=query(db,`SELECT agent_id FROM local_chain_member_versions m WHERE chain_id=?1 AND enabled=1 AND role='coordinator'
      AND accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id)
      UNION SELECT json_extract(config_json,'$.author_agent_id') FROM lifecycle_configs WHERE chain_id=?1 AND task_id=?2
      AND revision=(SELECT max(revision) FROM lifecycle_configs x WHERE x.chain_id=?1 AND x.task_id=?2)`,chain,task)
    if !ok do return nil,false
    out:=make([dynamic]string,context.temp_allocator)
    for r in rows do append(&out,r[0])
    return out[:],true
}
// The chain fleet rows serving a role now (the role and no '*' paused).
migration_037_fleet :: proc(db:DB,chain,role:string) -> ([]string,bool) {
    rows,ok:=query(db,`SELECT p.agent_id FROM local_fleet_policy_current p JOIN local_fleet_policy_roles r ON r.chain_id=p.chain_id AND r.agent_id=p.agent_id AND r.seq=p.seq
      WHERE p.chain_id=?1 AND r.role=?2 AND r.paused=0 AND NOT EXISTS(SELECT 1 FROM local_fleet_policy_roles x
        WHERE x.chain_id=p.chain_id AND x.agent_id=p.agent_id AND x.seq=p.seq AND x.paused=1 AND x.role IN (?2,'*')) ORDER BY p.agent_id`,chain,role)
    if !ok do return nil,false
    out:=make([dynamic]string,context.temp_allocator)
    for r in rows do append(&out,r[0])
    return out[:],true
}
// Map the roles named at path (a JSON array) inside raw. pairs are the
// task's configured [role, agent] rows ("" chain-level subjects have none).
migration_037_resolve :: proc(db:DB,chain,raw,path:string,pairs:[][]string,skip:[]string,out:^[dynamic]Migration_037_Mapping) -> bool {
    roles,ok:=query(db,"SELECT value FROM json_each(?1,?2) WHERE type='text' ORDER BY key",raw,path)
    if !ok do return false
    for row in roles {
        role:=row[0]
        found:=false
        for pair in pairs do if pair[0]==role && !slice.contains(skip,pair[1]) {
            append(out,Migration_037_Mapping{role,pair[1],"task_role_pairs"});found=true
        }
        if !found {
            holders,read:=migration_037_fleet(db,chain,role)
            if !read do return false
            for agent in holders do if !slice.contains(skip,agent) { append(out,Migration_037_Mapping{role,agent,"fleet_role"});found=true }
        }
        if !found do append(out,Migration_037_Mapping{role,"","user_approval"})
    }
    return true
}
// raw with the brief at path rewritten: review_roles removed, mapped
// agents appended to reviewers, requires_user_approval set when owed.
migration_037_rewrite :: proc(db:DB,raw,path:string,mappings:[]Migration_037_Mapping) -> (string,bool) {
    existing,ok:=query(db,"SELECT value FROM json_each(?1,?2) WHERE type='text' ORDER BY key",raw,fmt.tprintf("%s.reviewers",path))
    if !ok do return "",false
    reviewers:=make([dynamic]string,context.temp_allocator)
    for r in existing do if !slice.contains(reviewers[:],r[0]) do append(&reviewers,r[0])
    user:=false
    for m in mappings {
        if m.agent!="" && !slice.contains(reviewers[:],m.agent) do append(&reviewers,m.agent)
        if m.source=="user_approval" || m.source=="role_config_user_approval" do user=true
    }
    list,_:=json.marshal(reviewers[:],allocator=context.temp_allocator)
    rows,done:=query(db,`SELECT CASE WHEN ?4 THEN json_set(json_remove(?1,?2||'.review_roles'),?2||'.reviewers',json(?3),?2||'.requires_user_approval',json('true'))
      WHEN json_array_length(?3)>0 THEN json_set(json_remove(?1,?2||'.review_roles'),?2||'.reviewers',json(?3))
      ELSE json_remove(?1,?2||'.review_roles') END`,raw,path,string(list),"1" if user else "0")
    if !done || len(rows)!=1 do return "",false
    return rows[0][0],true
}

// A Hub-imported brief that still names review_roles (migration_import): the
// same mapping as V37, through the chain fleet only (an imported task has no
// review.roles configuration), recorded as requirements revision 1.
migration_037_import_brief :: proc(db:DB,chain,task,brief:string) -> (string,bool) {
    kind,typed:=query(db,"SELECT CASE WHEN json_valid(?1) THEN COALESCE(json_type(?1,'$.review_roles'),'') ELSE '' END",brief)
    if !typed || len(kind)!=1 do return "",false
    if kind[0][0]=="" do return brief,true
    skip,read:=migration_037_excluded(db,chain,task)
    if !read do return "",false
    mappings:=make([dynamic]Migration_037_Mapping,context.temp_allocator)
    if kind[0][0]=="array" && !migration_037_resolve(db,chain,brief,"$.review_roles",nil,skip,&mappings) do return "",false
    next,rewritten:=migration_037_rewrite(db,brief,"$",mappings[:])
    if !rewritten do return "",false
    for m in mappings do if !migration_037_record(db,chain,"requirements",task,"1",m) do return "",false
    return next,true
}

migration_037_review_roles :: proc(db:DB) -> bool {
    context.allocator=context.temp_allocator
    if !exec(db,"DROP TRIGGER IF EXISTS task_requirements_immutable; DROP TRIGGER IF EXISTS local_workflow_definitions_immutable; DROP TRIGGER IF EXISTS local_chain_defaults_no_update;") do return false
    // 1. Task briefs: every revision naming review_roles, and the latest
    // revision of a task with a review.roles configuration.
    briefs,ok:=query(db,`SELECT q.chain_id,q.task_id,q.revision,q.brief_json,q.revision=(SELECT max(x.revision) FROM task_requirements x WHERE x.chain_id=q.chain_id AND x.task_id=q.task_id)
      FROM task_requirements q WHERE json_valid(q.brief_json) AND json_type(q.brief_json)='object' AND (json_type(q.brief_json,'$.review_roles') IS NOT NULL
        OR (q.revision=(SELECT max(x.revision) FROM task_requirements x WHERE x.chain_id=q.chain_id AND x.task_id=q.task_id)
          AND EXISTS(SELECT 1 FROM local_role_configs c WHERE c.chain_id=q.chain_id AND c.task_id=q.task_id)))
      ORDER BY q.chain_id,q.task_id,q.revision`)
    if !ok do return false
    for row in briefs {
        chain,task,revision,raw,latest:=row[0],row[1],row[2],row[3],row[4]=="1"
        skip,read:=migration_037_excluded(db,chain,task)
        if !read do return false
        pairs,pread:=query(db,`SELECT role,agent_id FROM local_role_pairs p WHERE chain_id=? AND task_id=?
          AND revision=(SELECT max(revision) FROM local_role_configs c WHERE c.chain_id=p.chain_id AND c.task_id=p.task_id) ORDER BY role,agent_id`,chain,task)
        config,cread:=query(db,"SELECT requires_user_approval FROM local_role_configs WHERE chain_id=? AND task_id=? ORDER BY revision DESC LIMIT 1",chain,task)
        if !pread || !cread do return false
        mappings:=make([dynamic]Migration_037_Mapping)
        kind,typed:=query(db,"SELECT COALESCE(json_type(?1,'$.review_roles'),'')",raw)
        if !typed || len(kind)!=1 do return false
        if kind[0][0]=="array" && !migration_037_resolve(db,chain,raw,"$.review_roles",pairs[:],skip,&mappings) do return false
        if latest {
            for pair in pairs do if !slice.contains(skip,pair[1]) do append(&mappings,Migration_037_Mapping{pair[0],pair[1],"task_role_pairs"})
            if len(config)==1 && config[0][0]=="1" do append(&mappings,Migration_037_Mapping{"","","role_config_user_approval"})
        }
        next,rewritten:=migration_037_rewrite(db,raw,"$",mappings[:])
        if !rewritten do return false
        for m in mappings do if !migration_037_record(db,chain,"requirements",task,revision,m) do return false
        if next!=raw {
            if _,ok=query(db,"UPDATE task_requirements SET brief_json=? WHERE chain_id=? AND task_id=? AND revision=?",next,chain,task,revision);!ok do return false
        }
    }
    // 2. Role verdicts already posted count as those agents' reviews.
    carried:=exec(db,`INSERT OR IGNORE INTO local_reviews(chain_id,task_id,attempt,reviewer_agent_id,principal_id,operation_id,requirements_revision,head,verdict,summary,principal_kind)
      SELECT r.chain_id,r.task_id,r.attempt,r.agent_id,min(r.principal_id),min(r.operation_id),s.requirements_revision,s.head,
        CASE WHEN max(r.verdict='request_changes') THEN 'request_changes' ELSE 'approve' END,group_concat(r.summary,char(10)),'agent'
      FROM local_role_reviews r JOIN local_submissions s ON s.chain_id=r.chain_id AND s.task_id=r.task_id AND s.attempt=r.attempt
      GROUP BY r.chain_id,r.task_id,r.attempt,r.agent_id`)
    if !carried do return false
    // 3. Workflow definition stages and 4. pending proposal tasks.
    Subject :: struct { subject,select_sql,update_sql,path:string }
    subjects:=[2]Subject{
        {"workflow_definition",`SELECT d.chain_id,d.workflow_id,d.version,d.definition_json,s.key FROM local_workflow_definitions d,json_each(d.definition_json,'$.stages') s
          WHERE json_valid(d.definition_json) AND json_type(s.value,'$.brief.review_roles')='array' ORDER BY d.chain_id,d.workflow_id,d.version,s.key`,
         "UPDATE local_workflow_definitions SET definition_json=? WHERE chain_id=? AND workflow_id=? AND version=?","$.stages[%s].brief"},
        {"proposal",`SELECT d.chain_id,COALESCE(json_extract(t.value,'$.id'),json_extract(t.value,'$.task_id'),t.key),d.accepted_seq,d.defaults_json,t.key FROM local_chain_defaults_versions d,json_each(d.defaults_json,'$.proposal.tasks') t
          WHERE d.accepted_seq=(SELECT max(x.accepted_seq) FROM local_chain_defaults_versions x WHERE x.chain_id=d.chain_id)
            AND json_type(t.value,'$.brief.review_roles')='array' ORDER BY d.chain_id,t.key`,
         "UPDATE local_chain_defaults_versions SET defaults_json=? WHERE chain_id=? AND ?!='' AND accepted_seq=?","$.proposal.tasks[%s].brief"},
    }
    for subject in subjects {
        // One stage per pass: re-read after each rewrite so every path stays exact.
        for {
            rows,read:=query(db,fmt.tprintf("%s LIMIT 1",subject.select_sql))
            if !read do return false
            if len(rows)==0 do break
            r:=rows[0]
            chain,id,revision,raw:=r[0],r[1],r[2],r[3]
            path:=fmt.tprintf(subject.path,r[4])
            skip,sread:=migration_037_excluded(db,chain,"")
            if !sread do return false
            mappings:=make([dynamic]Migration_037_Mapping)
            if !migration_037_resolve(db,chain,raw,fmt.tprintf("%s.review_roles",path),nil,skip,&mappings) do return false
            next,rewritten:=migration_037_rewrite(db,raw,path,mappings[:])
            if !rewritten || next==raw do return false
            for m in mappings do if !migration_037_record(db,chain,subject.subject,id,revision,m) do return false
            if _,ok=query(db,subject.update_sql,next,chain,id,revision);!ok do return false
            // The search index row of a definition follows its text.
            if subject.subject=="workflow_definition" {
                if _,ok=query(db,"UPDATE search_docs SET body=? WHERE chain_id=? AND kind='workflow' AND object_id=?",next,chain,fmt.tprintf("%s:%s",id,revision));!ok do return false
            }
        }
    }
    return exec(db,MIGRATION_037_TRIGGERS)
}
