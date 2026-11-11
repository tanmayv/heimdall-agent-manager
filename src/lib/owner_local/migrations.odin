package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:slice"

// The owner-local store is flat: schema.sql is the whole schema at
// SCHEMA_VERSION (no released Bridge carries an owner store yet). A new
// database gets the schema; a database at any other version is refused, so an
// older pre-release store must be recreated. Once a release users run owner
// chains on ships, schema changes become numbered steps from this baseline.
SCHEMA_VERSION :: 38

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
    if version!=0 && version!=SCHEMA_VERSION do return false
    if version==0 {
        if !exec(db,string(SCHEMA)) do return false
        if _,ok=query(db,"INSERT INTO schema_migrations VALUES(1,?)",fmt.tprintf("%d",SCHEMA_VERSION));!ok do return false
    }
    if !exec(db,"COMMIT") do return false
    committed=true
    return true
}

// Hub-imported briefs that still name review_roles (migration_import) are
// mapped to reviewers: the role's chain fleet holders, else the user's approval.
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
