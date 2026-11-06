#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Import source facts, not a reconstruction from today's runtime rows. Native
// timestamps and payload/body documents remain verbatim strings. Snapshot
// revisions distinguish historical attempt updates without rewriting history.
native_json_object :: proc(raw:string)->bool {
    v,ok:=contracts.owner_request_document(raw)
    _,obj:=v.(json.Object)
    return ok && obj
}
native_references_valid :: proc(raw:string)->bool {
    v,ok:=contracts.owner_request_document(raw);items,arr:=v.(json.Array)
    if !ok || !arr || len(items)>100 do return false
    for value in items {
        ref,obj:=value.(json.Object)
        if !obj || len(ref)!=5 do return false
        for name in ([5]string{"kind","id","revision","provenance","state"}) {
            _,str:=ref[name].(json.String);if !str do return false
        }
        if field(ref,"kind")!="artifact" && field(ref,"kind")!="message" do return false
        if !contracts.owner_field_valid(field(ref,"id"),"id") || field(ref,"revision")=="" || field(ref,"provenance")=="" do return false
        if field(ref,"state")!="unresolved" && field(ref,"state")!="import_pending" do return false
    }
    return true
}

native_history_import :: proc(s:^Store,c:json.Object,raw:string,seq:i64)->string {
    if !transaction_current(s.active) do return "storage_error"
    bundle,valid:=contracts.owner_parse(raw,"native_history_bundle")
    if !valid do return "invalid_content"
    chain,task,source,owner:=field(c,"chain_id"),field(c,"task_id"),field(bundle,"source_revision"),field(bundle,"owner_user_id")
    owners,owners_ok:=query(s.db,"SELECT 1 FROM native_history_records WHERE chain_id=? AND task_id=? AND owner_user_id!=? LIMIT 1",chain,task,owner)
    if !owners_ok do return "storage_error"
    if len(owners)>0 do return "operation_conflict"
    count,read:=query(s.db,"SELECT count(*) FROM native_history_records")
    if !read do return "storage_error"
    if number(count[0][0])>=MAX_RECORDS do return "retention_capacity"
    total:=0
    for kind in ([3]string{"attempt","event","facet"}) {
        plural:=fmt.tprintf("%ss",kind)
        value,parsed:=contracts.owner_request_document(field(bundle,plural));items,arr:=value.(json.Array)
        if !parsed || !arr || len(items)>100 do return "invalid_content"
        for item in items {
            // The record itself is a document string so its original encoding
            // survives envelope parsing, replay, persistence and chunked reads.
            text,str:=item.(json.String)
            if !str do return "invalid_content"
            record_raw:=string(text)
            record,ok:=contracts.owner_parse(record_raw,fmt.tprintf("native_history_%s",kind))
            if !ok || field(record,"chain_id")!=chain || field(record,"task_id")!=task || field(record,"owner_user_id")!=owner || !native_json_object(field(record,"provenance_json")) do return "invalid_content"
            key,attempt,facet,version,writer:="",field(record,"attempt_no"),"","",""
            switch kind {
            case "attempt":
                key=attempt
                // Preserve timestamp spellings/timezones. Missing terminal
                // evidence is explicit, never filled from the importing clock.
                if len(field(record,"started_at"))>128 || len(field(record,"ended_at"))>128 || len(field(record,"outcome"))>128 do return "invalid_content"
                if (field(record,"ended_at")=="") != (field(record,"outcome")=="") do return "invalid_content"
            case "event":
                key=field(record,"event_id")
                if !native_json_object(field(record,"payload_json")) do return "invalid_content"
            case "facet":
                facet=field(record,"kind");version=field(record,"v");writer=field(record,"writer")
                key=encode([3]string{attempt,facet,version})
                if len(field(record,"written_at"))>128 || !native_json_object(field(record,"body_json")) || !native_references_valid(field(record,"references_json")) do return "invalid_content"
                parents,parent_ok:=query(s.db,"SELECT 1 FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind='attempt' AND record_key=?",chain,task,source,attempt)
                if !parent_ok do return "storage_error"
                if len(parents)!=1 do return "invalid_content"
                writers,writers_ok:=query(s.db,"SELECT 1 FROM native_history_records WHERE chain_id=? AND task_id=? AND record_kind='facet' AND attempt_no=? AND facet_kind=? AND writer!=? LIMIT 1",chain,task,attempt,facet,writer)
                if !writers_ok do return "storage_error"
                if len(writers)>0 do return "operation_conflict"
            }
            // Event identity and a given facet version are immutable even
            // across snapshots. Native attempt rows may change at a later
            // source revision; their earlier snapshot stays independently read.
            if kind!="attempt" {
                prior,found:=query(s.db,"SELECT record_json FROM native_history_records WHERE chain_id=? AND record_kind=? AND record_key=? AND (?='event' OR task_id=?)",chain,kind,key,kind,task)
                if !found do return "storage_error"
                for row in prior { if row[0]!=record_raw do return "operation_conflict" }
            }
            prior,found:=query(s.db,"SELECT record_json,owner_user_id,completeness FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind=? AND record_key=?",chain,task,source,kind,key)
            if !found do return "storage_error"
            if len(prior)>0 {
                if prior[0][0]!=record_raw || prior[0][1]!=owner || prior[0][2]!=field(bundle,"completeness") do return "operation_conflict"
                continue
            }
            _,inserted:=query(s.db,`INSERT INTO native_history_records VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,CASE WHEN ?='facet' THEN 'attempt' END,CASE WHEN ?='facet' THEN ? END)`,chain,task,source,kind,key,owner,field(bundle,"completeness"),attempt,facet,version,writer,record_raw,fmt.tprintf("%d",seq),kind,kind,attempt)
            if !inserted do return "storage_error"
            total+=1
            if number(count[0][0])+i64(total)>MAX_RECORDS do return "retention_capacity"
        }
    }
    return "ok"
}

// This API exposes source snapshots separately from C1a's current runtime
// projection. A declared import completeness is not budget admission authority.
native_history_read :: proc(s:^Store,c,p:json.Object)->Result {
    chain,task,source,kind:=field(c,"chain_id"),field(c,"task_id"),field(p,"source_revision"),field(p,"kind")
    if field(c,"method")=="native.history.fetch" {
        rows,ok:=query(s.db,"SELECT record_json,completeness FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind=? AND record_key=?",chain,task,source,kind,field(p,"key"))
        if !ok do return fail("storage_error")
        if len(rows)!=1 do return fail("invalid_scope")
        raw:=rows[0][0];offset:=number(field(p,"offset"))
        if offset>i64(len(raw)) || (offset<i64(len(raw)) && raw[offset]&0xc0==0x80) do return fail("malformed")
        end:=min(i64(len(raw)),offset+8192)
        for end>offset && end<i64(len(raw)) && raw[end]&0xc0==0x80 { end-=1 }
        next:="";if end<i64(len(raw)) do next=fmt.tprintf("%d",end)
        body:=encode(doc(map[string]string{"source_revision"=source,"kind"=kind,"key"=field(p,"key"),"record"=raw[offset:end],"next_offset"=next,"source_completeness"=rows[0][1]}))
        if len(body)>MAX_PAGE do return fail("invalid_content")
        return Result{code="ok",body=body}
    }
    scope:=contracts.owner_payload_digest(encode([6]string{s.account,chain,task,source,kind,"native.history.v1"}))
    after:="";cursor:=field(p,"cursor")
    if cursor!="" {
        if !strings.has_prefix(cursor,fmt.tprintf("%s:",scope)) do return fail("stale_cursor")
        after=cursor[len(scope)+1:]
    }
    limit:=number(field(p,"limit"))
    // Sort decimal identities as SQLite i64, never lexically or as JS floats.
    // Fixed-width cursor components also order facet versions numerically.
    rows,ok:=query(s.db,`WITH inventory AS (
      SELECT record_key,owner_user_id,completeness,length(CAST(record_json AS BLOB)) AS bytes,attempt_no,facet_kind,facet_version,writer,
        CASE WHEN record_kind='facet' THEN printf('%019d',CAST(attempt_no AS INTEGER))||':'||facet_kind||':'||printf('%019d',CAST(facet_version AS INTEGER))
          ELSE printf('%019d',CAST(record_key AS INTEGER)) END AS sort_key
      FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind=?)
      SELECT record_key,owner_user_id,completeness,bytes,attempt_no,facet_kind,facet_version,writer,sort_key FROM inventory WHERE sort_key>? ORDER BY sort_key LIMIT ?`,chain,task,source,kind,after,fmt.tprintf("%d",limit+1))
    if !ok do return fail("storage_error")
    items:=make([dynamic]json.Value,context.temp_allocator)
    next:=""
    for row,i in rows {
        if i>=int(limit) do break
        append(&items,doc(map[string]string{"key"=row[0],"owner_user_id"=row[1],"source_completeness"=row[2],"record_bytes"=row[3],"attempt_no"=row[4],"facet_kind"=row[5],"v"=row[6],"writer"=row[7]}))
        next=fmt.tprintf("%s:%s",scope,row[8])
    }
    if len(items)==len(rows) do next=""
    body:=doc(map[string]string{"source_revision"=source,"kind"=kind,"next_cursor"=next})
    body["items"]=json.Array(items)
    encoded:=encode(body)
    if len(encoded)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=encoded}
}
