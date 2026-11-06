#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import contracts "odin_test:contracts"

// One original owner spans every source kind and every task in a chain.
// Older databases may contain history imported before origins existed; inspect
// those immutable rows before lazily establishing the shared origin. The caller
// owns the transaction, so a later validation or COMMIT failure rolls it back.
native_origin_accept :: proc(s:^Store,chain,owner:string,seq:i64) -> string {
    if !transaction_current(s.active) do return "storage_error"
    conflicts,ok:=query(s.db,"SELECT 1 FROM native_history_records WHERE chain_id=? AND owner_user_id!=? UNION ALL SELECT 1 FROM native_metadata_origins WHERE chain_id=? AND owner_user_id!=? LIMIT 1",chain,owner,chain,owner)
    if !ok do return "storage_error"
    if len(conflicts)>0 do return "operation_conflict"
    _,ok=query(s.db,"INSERT INTO native_metadata_origins(chain_id,owner_user_id,accepted_seq) SELECT ?,?,COALESCE((SELECT min(accepted_seq) FROM native_history_records WHERE chain_id=?),?) WHERE NOT EXISTS(SELECT 1 FROM native_metadata_origins WHERE chain_id=?)",chain,owner,chain,fmt.tprintf("%d",seq),chain)
    if !ok do return "storage_error"
    return "ok"
}

// Imports are immutable source facts. They never configure a lifecycle
// directory, enroll a member, launch a child, or change an operational role.
native_metadata_import :: proc(s:^Store,c:json.Object,raw:string,seq:i64) -> string {
    if !transaction_current(s.active) do return "storage_error"
    bundle,valid:=contracts.owner_metadata_import_parse(raw)
    if !valid do return "invalid_content"
    chain:=field(c,"chain_id")
    if bundle.chain_id!=chain do return "invalid_scope"
    source,kind,owner:=bundle.source_revision,bundle.kind,bundle.owner_user_id
    manifest:="native_metadata_snapshots"
    if kind=="fleet" do manifest="native_fleet_snapshots"
    if len(contracts.owner_metadata_fact_fields(kind))>0 do manifest="native_fact_snapshots"
    prior,ok:=query(s.db,fmt.tprintf("SELECT content_digest FROM %s WHERE chain_id=? AND source_revision=? AND kind=?",manifest),chain,source,kind)
    if !ok do return "storage_error"
    digest:=contracts.owner_payload_digest(raw)
    if len(prior)>0 {
        if prior[0][0]!=digest do return "operation_conflict"
        return "ok"
    }
    if code:=native_origin_accept(s,chain,owner,seq); code!="ok" do return code
    count,count_ok:=query(s.db,"SELECT (SELECT count(*) FROM native_fleet_policies)+(SELECT count(*) FROM native_fleet_snapshots)+(SELECT count(*) FROM native_metadata_members)+(SELECT count(*) FROM native_metadata_directories)+(SELECT count(*) FROM native_metadata_snapshots)+(SELECT count(*) FROM native_fact_snapshots)+(SELECT count(*) FROM native_fact_chain)+(SELECT count(*) FROM native_fact_task)+(SELECT count(*) FROM native_fact_comment)+(SELECT count(*) FROM native_fact_summary)")
    if !count_ok do return "storage_error"
    if number(count[0][0])+i64(len(bundle.records))+1>MAX_RECORDS do return "retention_capacity"
    stamp:=fmt.tprintf("%d",seq)
    if _,ok=query(s.db,fmt.tprintf("INSERT INTO %s VALUES(?,?,?,?,?,?,?)",manifest),chain,source,kind,owner,stamp,fmt.tprintf("%d",len(bundle.records)),digest); !ok do return "storage_error"
    for row in bundle.records {
        if kind=="fleet" {
            policy,parsed:=contracts.owner_fleet_policy_parse(encode(row))
            if !parsed do return "invalid_content"
            if code:=native_fleet_insert(s,source,policy);code!="ok" do return code
        } else if len(contracts.owner_metadata_fact_fields(kind))>0 {
            code:=native_fact_insert(s,source,kind,row)
            if code!="ok" do return code
        } else if kind=="member" {
            _,ok=query(s.db,"INSERT INTO native_metadata_members VALUES(?,?,?,?,?,?,?,?)",chain,source,kind,field(row,"agent_instance_id"),field(row,"agent_id"),owner,field(row,"role"),field(row,"created_at"))
        } else {
            // Native directory IDs are globally unique, even across snapshots.
            existing,found:=query(s.db,"SELECT 1 FROM native_metadata_directories WHERE directory_id=? AND chain_id!=? LIMIT 1",field(row,"directory_id"),chain)
            if !found do return "storage_error"
            if len(existing)>0 do return "operation_conflict"
            _,ok=query(s.db,"INSERT INTO native_metadata_directories VALUES(?,?,?,?,?,?,?,?,?,?,?)",chain,source,kind,field(row,"directory_id"),owner,field(row,"path"),field(row,"bridge_id"),field(row,"vcs_kind"),field(row,"vcs_info_json"),field(row,"created_at"),field(row,"updated_at"))
        }
        if !ok do return "storage_error"
    }
    return "ok"
}

native_metadata_read :: proc(s:^Store,chain:string,p:json.Object) -> Result {
    source,kind:=field(p,"source_revision"),field(p,"kind")
    manifest:="native_metadata_snapshots"
    if kind=="fleet" do manifest="native_fleet_snapshots"
    fields:=contracts.owner_metadata_fact_fields(kind)
    if len(fields)>0 do manifest="native_fact_snapshots"
    snapshot,ok:=query(s.db,fmt.tprintf("SELECT owner_user_id,accepted_seq,record_count,content_digest FROM %s WHERE chain_id=? AND source_revision=? AND kind=?",manifest),chain,source,kind)
    if !ok do return fail("storage_error")
    if len(snapshot)!=1 do return fail("invalid_scope")
    // Immutable source pages are independent of later local edits; the exact
    // source, kind, account, chain and content digest bind every page token.
    scope:=contracts.owner_payload_digest(encode([6]string{s.account,chain,source,kind,snapshot[0][3],"native.metadata.v1"}))
    after:=""
    cursor:=field(p,"cursor")
    if cursor!="" {
        if len(cursor)<65 || cursor[:64]!=scope || cursor[64]!=':' do return fail("stale_cursor")
        after=cursor[65:]
        // Empty native member identities sort before every non-empty ID.
        if !contracts.owner_field_valid(after,"optional") do return fail("malformed")
    }
    table,key:="native_metadata_members","agent_instance_id"
    if kind=="fleet" { table="native_fleet_policies";key="agent_id" }
    if kind=="directory" { table="native_metadata_directories";key="directory_id" }
    if len(fields)>0 { table=fmt.tprintf("native_fact_%s",kind);key=contracts.owner_metadata_fact_key(kind) }
    rows,read:=query(s.db,fmt.tprintf("SELECT * FROM %s WHERE chain_id=? AND source_revision=? AND (?='' OR %s>?) ORDER BY %s LIMIT ?",table,key,key),chain,source,cursor,after,fmt.tprintf("%d",number(field(p,"limit"))+1))
    if !read do return fail("storage_error")
    result:=doc(map[string]string{"chain_id"=chain,"source_revision"=source,"kind"=kind,"owner_user_id"=snapshot[0][0],"accepted_seq"=snapshot[0][1],"record_count"=snapshot[0][2],"next_cursor"=""})
    items:=make([dynamic]json.Value,context.temp_allocator)
    last:=after
    for row,i in rows {
        if i>=int(number(field(p,"limit"))) do break
        record:=make(json.Object,context.temp_allocator)
        if kind=="fleet" {
            policy:=native_fleet_document(row)
            value,valid:=contracts.owner_content_document(encode(policy))
            object,obj:=value.(json.Object)
            if !valid || !obj do return fail("storage_error")
            record=object
        } else if len(fields)>0 {
            for f,i in fields {
                switch f.kind {
                case "integer": record[f.name]=json.Integer(number(row[2+i]))
                case "boolean": record[f.name]=json.Boolean(row[2+i]=="1")
                case: record[f.name]=json.String(row[2+i])
                }
            }
        } else if kind=="member" {
            record=doc(map[string]string{"chain_id"=row[0],"agent_instance_id"=row[3],"agent_id"=row[4],"owner_user_id"=row[5],"role"=row[6],"created_at"=row[7]})
        } else {
            record=doc(map[string]string{"directory_id"=row[3],"chain_id"=row[0],"owner_user_id"=row[4],"path"=row[5],"bridge_id"=row[6],"vcs_kind"=row[7],"vcs_info_json"=row[8],"created_at"=row[9],"updated_at"=row[10]})
        }
        append(&items,record)
        result["items"]=json.Array(items)
        result["next_cursor"]=json.String(fmt.tprintf("%s:%s",scope,field(record,key)))
        if len(encode(result))>MAX_PAGE {
            ordered_remove(&items,len(items)-1)
            break
        }
        last=field(record,key)
    }
    if len(rows)>0 && len(items)==0 do return fail("invalid_content")
    next:=""
    if len(items)<len(rows) do next=fmt.tprintf("%s:%s",scope,last)
    result["items"]=json.Array(items)
    result["next_cursor"]=json.String(next)
    return Result{code="ok",body=encode(result)}
}

// The schema and identifiers come only from strict contract descriptors. Native
// scalar values are bound individually into normalized columns, never stored as
// an opaque JSON document that ordinary readers would have to interpret.
native_fact_insert :: proc(s:^Store,source,kind:string,row:json.Object) -> string {
    fields:=contracts.owner_metadata_fact_fields(kind)
    key:=contracts.owner_metadata_fact_key(kind)
    if len(fields)==0 || key=="" do return "invalid_content"
    table:=fmt.tprintf("native_fact_%s",kind)
    existing,ok:=query(s.db,fmt.tprintf("SELECT 1 FROM %s WHERE %s=? AND chain_id!=? LIMIT 1",table,key),field(row,key),field(row,"chain_id"))
    if !ok do return "storage_error"
    if len(existing)>0 do return "operation_conflict"
    names,marks:="source_revision,snapshot_kind","?,?"
    args:=make([dynamic]string,context.temp_allocator)
    append(&args,source,kind)
    for f in fields {
        names=fmt.tprintf("%s,%s",names,f.name)
        marks=fmt.tprintf("%s,?",marks)
        switch f.kind {
        case "integer": append(&args,encode(row[f.name]))
        case "boolean":
            value,_:=row[f.name].(json.Boolean)
            append(&args, "1" if bool(value) else "0")
        case: append(&args,field(row,f.name))
        }
    }
    _,ok=query(s.db,fmt.tprintf("INSERT INTO %s(%s) VALUES(%s)",table,names,marks),..args[:])
    if !ok do return "storage_error"
    return "ok"
}
