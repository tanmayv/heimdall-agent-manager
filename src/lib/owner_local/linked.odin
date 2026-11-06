#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// Linked records are immutable, chain-scoped versions. Blobs are bounded
// encrypted chunks; artifact references supply their order. No filesystem path
// in a producer record is ever opened. Only message prose enters search.
linked_key :: proc(o:json.Object)->[3]string {
    return {field(o,"kind"),field(o,"object_id"),field(o,"revision")}
}
linked_array :: proc(raw:string)->(json.Array,bool) {
    // Reference/tombstone arrays use strict ASCII authority-compatible JSON.
    // Object arrays carry opaque Unicode record strings with the native grammar.
    value,strict:=contracts.owner_request_document(raw)
    if strict {
        items,arr:=value.(json.Array)
        return items,arr && len(items)<=100
    }
    if !native_content_grammar(raw,false) do return nil,false
    v,e:=json.parse_string(raw,.JSON,true,context.temp_allocator)
    items,arr:=v.(json.Array)
    return items,e==nil && arr && len(items)<=100
}
linked_retired :: proc(s:^Store,chain:string,k:[3]string)->(bool,bool) {
    rows,ok:=query(s.db,"SELECT 1 FROM linked_tombstones WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,k[0],k[1],k[2])
    return len(rows)>0,ok
}
linked_refs :: proc(s:^Store,chain:string,o:json.Object,restore:bool)->string {
    refs,valid:=linked_array(field(o,"references"))
    if !valid do return "invalid_content"
    k:=linked_key(o)
    for value in refs {
        ref,obj:=value.(json.Object)
        if !obj || !contracts.owner_document_valid("linked_reference",ref) do return "invalid_content"
        target:=linked_key(ref)
        if target==k do return "invalid_content"
        rows,ok:=query(s.db,"SELECT 1 FROM linked_bodies WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,target[0],target[1],target[2])
        if !ok do return "storage_error"
        retired,read:=linked_retired(s,chain,target)
        if !read do return "storage_error"
        if len(rows)!=1 && !(restore && retired) do return "invalid_scope"
        if retired && !restore do return "retired"
        // A tombstone imported without its deleted body still has an identity.
        if _,ok=query(s.db,"INSERT OR IGNORE INTO linked_references VALUES(?,?,?,?,?,?,?)",chain,k[0],k[1],k[2],target[0],target[1],target[2]);!ok do return "storage_error"
    }
    return "ok"
}
linked_insert :: proc(s:^Store,c:json.Object,raw:string,seq:i64,kr:^vault.Vault_Keyring,restore:bool)->string {
    if len(encode(raw))>20000 do return "invalid_content" // every admitted record fits an encrypted manifest page
    o,valid:=native_content_parse(raw,"linked_object")
    if !valid || field(o,"account_id")!=s.account || field(o,"owner_bridge_id")!=s.owner || field(o,"chain_id")!=field(c,"chain_id") || len(field(o,"media_type"))>256 || len(field(o,"provenance"))>4096 do return "invalid_scope"
    chain,task:=field(c,"chain_id"),field(o,"task_id")
    k:=linked_key(o)
    if task!="" {
        rows,ok:=query(s.db,"SELECT 1 FROM tasks WHERE chain_id=? AND task_id=?",chain,task)
        if !ok do return "storage_error"
        if len(rows)!=1 {
            // Deleted task history is only restored under its durable tombstone.
            deleted,read:=query(s.db,"SELECT 1 FROM task_deletions WHERE chain_id=? AND task_id=?",chain,task)
            if !read do return "storage_error"
            if !restore || len(deleted)!=1 do return "invalid_scope"
            return linked_remove(s,chain,k,seq,true,task)
        }
    }
    retired,read:=linked_retired(s,chain,k)
    if !read do return "storage_error"
    if retired {
        if restore do return "ok" // never resurrect an older backup
        return "retired"
    }
    old,ok:=query(s.db,"SELECT record_json FROM linked_bodies WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,k[0],k[1],k[2])
    if !ok do return "storage_error"
    if len(old)>0 {
        return "ok" if old[0][0]==raw else "operation_conflict"
    }
    cipher:=field(o,"body_cipher")
    plain,opened:=vault.open(cipher,kr,context.temp_allocator)
    if opened!=.Ok || len(plain)>MAX_BODY || len(encode(plain))>MAX_ENCODED_FIELD do return "invalid_content"
    id,epoch,_,parsed:=vault.envelope_parse(cipher,context.temp_allocator)
    if parsed!=.Ok do return "invalid_content"
    count,checked:=query(s.db,"SELECT (SELECT count(*) FROM linked_identities)+(SELECT count(*) FROM linked_tombstones)")
    if !checked do return "storage_error"
    if number(count[0][0])>=MAX_RECORDS do return "retention_capacity"
    refs,refs_ok:=linked_array(field(o,"references"))
    if !refs_ok do return "invalid_content"
    // New content may only reference older stored versions: no cycles. Restore
    // uses the same topological order from the backup inventory.
    for value in refs {
        ref,obj:=value.(json.Object)
        if !obj || !contracts.owner_document_valid("linked_reference",ref) do return "invalid_content"
        target:=linked_key(ref)
        if target==k do return "invalid_content"
        targets,read:=query(s.db,"SELECT 1 FROM linked_identities WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,target[0],target[1],target[2])
        if !read do return "storage_error"
        if len(targets)!=1 do return "invalid_scope"
    }
    if _,ok=query(s.db,"INSERT INTO linked_identities VALUES(?,?,?,?,?,?)",chain,k[0],k[1],k[2],task,fmt.tprintf("%d",seq));!ok do return "storage_error"
    prose:=""
    if k[0]=="message" do prose=plain
    if _,ok=query(s.db,"INSERT INTO linked_bodies VALUES(?,?,?,?,?,?,?,?)",chain,k[0],k[1],k[2],raw,vault.hex_encode_lower(id[:],context.temp_allocator),fmt.tprintf("%d",epoch),prose);!ok do return "storage_error"
    return linked_refs(s,chain,o,restore)
}

// Tombstones precede body removal. Incoming references retain their identity;
// outgoing blob references are collected only when the last live source drops
// them. No external file is unlinked, and audit ciphertext is not erased.
linked_remove :: proc(s:^Store,chain:string,k:[3]string,seq:i64,restore:bool,task:="")->string {
    rows,ok:=query(s.db,"SELECT task_id FROM linked_identities WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,k[0],k[1],k[2])
    if !ok do return "storage_error"
    if len(rows)==0 && !restore do return "invalid_scope"
    if restore && len(rows)==1 && rows[0][0]!=task do return "operation_conflict"
    if len(rows)==0 {
        count,checked:=query(s.db,"SELECT count(*) FROM linked_identities")
        if !checked do return "storage_error"
        if number(count[0][0])>=MAX_RECORDS do return "retention_capacity"
        if _,ok=query(s.db,"INSERT INTO linked_identities VALUES(?,?,?,?,?,?)",chain,k[0],k[1],k[2],task,fmt.tprintf("%d",seq));!ok do return "storage_error"
    }
    if _,ok=query(s.db,"INSERT OR IGNORE INTO linked_tombstones VALUES(?,?,?,?,?)",chain,k[0],k[1],k[2],fmt.tprintf("%d",seq));!ok do return "storage_error"
    children,read:=query(s.db,"SELECT target_kind,target_id,target_revision FROM linked_references WHERE chain_id=? AND source_kind=? AND source_id=? AND source_revision=?",chain,k[0],k[1],k[2])
    if !read do return "storage_error"
    if _,ok=query(s.db,"DELETE FROM linked_references WHERE chain_id=? AND source_kind=? AND source_id=? AND source_revision=?",chain,k[0],k[1],k[2]);!ok do return "storage_error"
    if _,ok=query(s.db,"DELETE FROM linked_bodies WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,k[0],k[1],k[2]);!ok do return "storage_error"
    // A restore page is only a partial graph: a later page may contain a live
    // source pin. Never turn a temporary absence of pins into a permanent local
    // deletion. Apply only explicit imported tombstones; ordinary signed delete
    // and task deletion still infer GC from their complete current live graph.
    if restore do return "ok"
    // Iterative queue avoids unbounded recursion for a deep chunk manifest.
    queue:=make([dynamic][3]string,context.temp_allocator)
    for row in children { if row[0]=="blob" do append(&queue,[3]string{row[0],row[1],row[2]}) }
    for i:=0;i<len(queue);i+=1 {
        if i>=MAX_RECORDS do return "retention_capacity"
        child:=queue[i]
        pins,pinned:=query(s.db,"SELECT 1 FROM linked_references WHERE chain_id=? AND target_kind=? AND target_id=? AND target_revision=? LIMIT 1",chain,child[0],child[1],child[2])
        if !pinned do return "storage_error"
        if len(pins)>0 do continue
        next,next_ok:=query(s.db,"SELECT target_kind,target_id,target_revision FROM linked_references WHERE chain_id=? AND source_kind=? AND source_id=? AND source_revision=?",chain,child[0],child[1],child[2])
        if !next_ok do return "storage_error"
        if _,ok=query(s.db,"INSERT OR IGNORE INTO linked_tombstones VALUES(?,?,?,?,?)",chain,child[0],child[1],child[2],fmt.tprintf("%d",seq));!ok do return "storage_error"
        if _,ok=query(s.db,"DELETE FROM linked_references WHERE chain_id=? AND source_kind=? AND source_id=? AND source_revision=?",chain,child[0],child[1],child[2]);!ok do return "storage_error"
        if _,ok=query(s.db,"DELETE FROM linked_bodies WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,child[0],child[1],child[2]);!ok do return "storage_error"
        for row in next {
            if row[0]=="blob" {
                if len(queue)>=MAX_RECORDS do return "retention_capacity"
                append(&queue,[3]string{row[0],row[1],row[2]})
            }
        }
    }
    return "ok"
}
linked_command :: proc(s:^Store,c,p:json.Object,body:string,seq:i64,kr:^vault.Vault_Keyring)->string {
    if !transaction_current(s.active) do return "storage_error"
    chain,method:=field(c,"chain_id"),field(c,"method")
    switch method {
    case "linked.put": return linked_insert(s,c,body,seq,kr,false)
    case "linked.delete": return linked_remove(s,chain,linked_key(p),seq,false)
    case "linked.restore":
        bundle,valid:=native_content_parse(body,"linked_restore")
        if !valid || field(bundle,"account_id")!=s.account || field(bundle,"owner_bridge_id")!=s.owner || field(bundle,"chain_id")!=chain do return "invalid_scope"
        tombstones,tomb_ok:=linked_array(field(bundle,"tombstones"))
        objects,obj_ok:=linked_array(field(bundle,"objects"))
        if !tomb_ok || !obj_ok do return "invalid_content"
        // All deletions are installed before any restored record is exposed.
        for value in tombstones {
            o,obj:=value.(json.Object)
            if !obj || !contracts.owner_document_valid("linked_tombstone",o) do return "invalid_content"
            task:=field(o,"task_id")
            if task!="" {
                tasks,read:=query(s.db,"SELECT 1 FROM tasks WHERE chain_id=? AND task_id=? UNION ALL SELECT 1 FROM task_deletions WHERE chain_id=? AND task_id=?",chain,task,chain,task)
                if !read do return "storage_error"
                if len(tasks)!=1 do return "invalid_scope"
            }
            if code:=linked_remove(s,chain,linked_key(o),seq,true,task);code!="ok" do return code
        }
        for value in objects {
            raw,str:=value.(json.String)
            if !str do return "invalid_content"
            if code:=linked_insert(s,c,string(raw),seq,kr,true);code!="ok" do return code
        }
        return "ok"
    }
    return "malformed"
}
linked_fetch :: proc(s:^Store,chain:string,p:json.Object)->Result {
    k:=linked_key(p)
    rows,ok:=query(s.db,"SELECT record_json FROM linked_bodies WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,k[0],k[1],k[2])
    if !ok do return fail("storage_error")
    if len(rows)!=1 {
        retired,read:=linked_retired(s,chain,k)
        if !read do return fail("storage_error")
        return fail("retired" if retired else "invalid_scope")
    }
    raw:=rows[0][0];offset:=number(field(p,"offset"))
    if offset>i64(len(raw)) || (offset<i64(len(raw)) && raw[offset]&0xc0==0x80) do return fail("malformed")
    end:=min(i64(len(raw)),offset+8192)
    for end>offset && end<i64(len(raw)) && raw[end]&0xc0==0x80 {end-=1}
    next:=""
    if end<i64(len(raw)) do next=fmt.tprintf("%d",end)
    return Result{code="ok",body=encode(doc(map[string]string{"record"=raw[offset:end],"offset"=field(p,"offset"),"next_offset"=next}))}
}

// A fail-on-change manifest: tombstones first, then bodies in dependency order.
// Every page is an authenticated vault envelope; there is no plaintext portable
// backup. The caller must retain all pages, original scope and required epochs.
linked_inventory :: proc(s:^Store,c,p:json.Object,kr:^vault.Vault_Keyring)->Result {
    chain:=field(c,"chain_id")
    state,ok:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !ok || len(state)!=1 do return fail("storage_error")
    scope:=contracts.owner_payload_digest(encode([6]string{s.account,s.owner,chain,field(c,"principal_id"),field(c,"key_id"),state[0][0]}))
    after:="0";stage:="0"
    if cursor:=field(p,"cursor");cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=3 || parts[0]!=scope || (parts[1]!="0" && parts[1]!="1") || !contracts.owner_field_valid(parts[2],"counter") do return fail("stale_cursor")
        stage=parts[1];after=parts[2]
    }
    limit:=field(p,"limit")
    rows:[dynamic][]string
    if stage=="0" {
        rows,ok=query(s.db,"SELECT t.rowid,t.kind,t.object_id,t.revision,i.task_id FROM linked_tombstones t JOIN linked_identities i ON i.chain_id=t.chain_id AND i.kind=t.kind AND i.object_id=t.object_id AND i.revision=t.revision WHERE t.chain_id=? AND t.rowid>? ORDER BY t.rowid LIMIT ?",chain,after,fmt.tprintf("%d",number(limit)+1))
    } else {
        rows,ok=query(s.db,"SELECT i.rowid,b.record_json,b.vault_id,b.key_epoch FROM linked_identities i JOIN linked_bodies b USING(chain_id,kind,object_id,revision) WHERE i.chain_id=? AND i.rowid>? ORDER BY i.rowid LIMIT ?",chain,after,fmt.tprintf("%d",number(limit)+1))
    }
    if !ok do return fail("storage_error")
    objects:=make([dynamic]string,context.temp_allocator)
    tombstones:=make([dynamic]json.Value,context.temp_allocator)
    keys:=make([dynamic]json.Value,context.temp_allocator)
    last:=after
    for row,i in rows {
        if i>=int(number(limit)) do break
        if stage=="0" {append(&tombstones,doc(map[string]string{"kind"=row[1],"object_id"=row[2],"revision"=row[3],"task_id"=row[4]}))} else {
            append(&objects,row[1])
            append(&keys,doc(map[string]string{"vault_id"=row[2],"epoch"=row[3]}))
        }
        // Bound before adding another record, with room for outer encryption.
        if len(linked_manifest_raw(s,chain,objects[:],tombstones[:]))*4/3+len(encode(keys))+2048>MAX_PAGE {
            if stage=="0" {ordered_remove(&tombstones,len(tombstones)-1)} else {ordered_remove(&objects,len(objects)-1);ordered_remove(&keys,len(keys)-1)}
            break
        }
        last=row[0]
    }
    used:=len(objects)+len(tombstones)
    if len(rows)>0 && used==0 do return fail("invalid_content")
    next:=""
    if used<len(rows) {next=fmt.tprintf("%s:%s:%s",scope,stage,last)} else if stage=="0" {next=fmt.tprintf("%s:1:0",scope)}
    raw:=linked_manifest_raw(s,chain,objects[:],tombstones[:])
    sealed,sealed_ok:=vault.seal_string(raw,kr,context.temp_allocator)
    if !sealed_ok do return fail("invalid_content")
    result:=doc(map[string]string{"next_cursor"=next,"manifest_cipher"=sealed,"manifest_digest"=contracts.owner_payload_digest(raw),"chain_revision"=state[0][0],"required_keys"=encode(keys)})
    encoded:=encode(result)
    if len(encoded)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=encoded}
}


linked_task_delete :: proc(s:^Store,chain,task:string,seq:i64)->bool {
    rows,ok:=query(s.db,"SELECT b.kind,b.object_id,b.revision FROM linked_bodies b JOIN linked_identities i USING(chain_id,kind,object_id,revision) WHERE i.chain_id=? AND i.task_id=?",chain,task)
    if !ok do return false
    for row in rows { if linked_remove(s,chain,[3]string{row[0],row[1],row[2]},seq,false)!="ok" do return false }
    return true
}

linked_facet_read :: proc(s:^Store,chain:string,p:json.Object)->Result {
    rows,ok:=query(s.db,"SELECT record_json FROM native_history_records WHERE chain_id=? AND task_id=? AND source_revision=? AND record_kind='facet' AND record_key=?",chain,field(p,"task_id"),field(p,"source_revision"),field(p,"key"))
    if !ok do return fail("storage_error")
    if len(rows)!=1 do return fail("invalid_scope")
    facet,valid:=native_content_parse(rows[0][0],"native_history_facet")
    if !valid do return fail("invalid_content")
    refs,arr_ok:=linked_array(field(facet,"references_json"))
    if !arr_ok do return fail("invalid_content")
    resolved:=make([dynamic]json.Value,context.temp_allocator)
    for value in refs {
        ref,obj:=value.(json.Object)
        if !obj do return fail("invalid_content")
        kind,id,revision:=field(ref,"kind"),field(ref,"id"),field(ref,"revision")
        if !contracts.owner_field_valid(revision,"positive") {
            append(&resolved,doc(map[string]string{"kind"=kind,"id"=id,"revision"=revision,"state"="unresolved"}))
            continue
        }
        bodies,read:=query(s.db,"SELECT 1 FROM linked_bodies WHERE chain_id=? AND kind=? AND object_id=? AND revision=?",chain,kind,id,revision)
        if !read do return fail("storage_error")
        retired,read_tomb:=linked_retired(s,chain,[3]string{kind,id,revision})
        if !read_tomb do return fail("storage_error")
        state:="unresolved"
        if len(bodies)==1 do state="resolved"
        if retired do state="deleted"
        append(&resolved,doc(map[string]string{"kind"=kind,"id"=id,"revision"=revision,"state"=state}))
    }
    body:=encode(struct{references:[dynamic]json.Value}{resolved})
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}

// Events remain the canonical signed envelope carrier. Inventory points to
// exact event/field locations and records format/vault/epoch without duplicating
// the canonical body. Pre-event evidence remains explicitly incomplete.
envelope_inventory :: proc(s:^Store,c,p:json.Object)->Result {
    chain:=field(c,"chain_id")
    state,ok:=query(s.db,"SELECT revision FROM task_chains WHERE chain_id=?",chain)
    if !ok || len(state)!=1 do return fail("storage_error")
    scope:=contracts.owner_payload_digest(encode([7]string{s.account,s.owner,chain,field(c,"principal_id"),field(c,"key_id"),state[0][0],"envelopes.v1"}))
    after:="0"
    if cursor:=field(p,"cursor");cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope || !contracts.owner_field_valid(parts[1],"counter") do return fail("stale_cursor")
        after=parts[1]
    }
    limit:=number(field(p,"limit"))
    rows,read:=query(s.db,"SELECT seq,kind,completeness,evidence_json FROM local_events WHERE chain_id=? AND seq>? ORDER BY seq LIMIT ?",chain,after,fmt.tprintf("%d",limit+1))
    if !read do return fail("storage_error")
    items:=make([dynamic]json.Value,context.temp_allocator)
    last:=after
    for row,i in rows {
        if i>=int(limit) do break
        evidence,err:=json.parse_string(row[3],.JSON,true,context.temp_allocator)
        o,obj:=evidence.(json.Object)
        if err!=nil || !obj do return fail("invalid_content")
        envelopes:=make([dynamic]json.Value,context.temp_allocator)
        if payload:=field(o,"payload");payload!="" {
            value,parsed:=contracts.owner_request_document(payload)
            fields,payload_obj:=value.(json.Object)
            if !parsed || !payload_obj do return fail("invalid_content")
            // Fixed order is stable across runtime map iteration orders.
            for name in ([4]string{"title_cipher","description_cipher","body_cipher","query_cipher"}) {
                token:=field(fields,name)
                if token=="" do continue
                id,epoch,_,result:=vault.envelope_parse(token,context.temp_allocator)
                if result!=.Ok do return fail("invalid_content")
                append(&envelopes,doc(map[string]string{"field"=name,"format"="vault.v2","vault_id"=vault.hex_encode_lower(id[:],context.temp_allocator),"epoch"=fmt.tprintf("%d",epoch),"cipher_digest"=contracts.owner_payload_digest(token)}))
            }
        }
        item:=doc(map[string]string{"seq"=row[0],"method"=row[1],"completeness"=row[2],"envelopes"=encode(envelopes)})
        append(&items,item)
        if len(encode(items))>MAX_PAGE-2048 {ordered_remove(&items,len(items)-1);break}
        last=row[0]
    }
    if len(rows)>0 && len(items)==0 do return fail("invalid_content")
    next:=""
    if len(items)<len(rows) do next=fmt.tprintf("%s:%s",scope,last)
    return Result{code="ok",body=encode(struct{items:[dynamic]json.Value,next_cursor:string,format:string}{items,next,"event-envelope-inventory.v1"})}
}



linked_manifest_raw :: proc(s:^Store,chain:string,objects:[]string,tombstones:[]json.Value)->string {
    return encode(doc(map[string]string{"account_id"=s.account,"owner_bridge_id"=s.owner,"chain_id"=chain,"format"="1","objects"=encode(objects),"tombstones"=encode(tombstones)}))
}
