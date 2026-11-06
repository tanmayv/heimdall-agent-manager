#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:c"
import contracts "odin_test:contracts"
import vault "odin_test:lib/vault"

// No global bm25 score: its corpus statistics reveal other scopes.
SEARCH_MAX_QUERY :: 256
SEARCH_MAX_HITS :: 50
SEARCH_VM_BUDGET :: 2000
search_budget :: proc "c"(data:rawptr)->c.int {
    remaining:=(^int)(data)
    remaining^-=1
    return 1 if remaining^<=0 else 0
}
search_literal :: proc(text:string)->(string,bool) {
    if len(text)>SEARCH_MAX_QUERY || len(strings.trim_space(text))<2 do return "",false
    words:=strings.fields(text,context.temp_allocator)
    if len(words)==0 || len(words)>16 do return "",false
    b:strings.Builder
    strings.builder_init(&b,context.temp_allocator)
    for word,i in words {
        if i>0 do strings.write_string(&b," AND ")
        strings.write_byte(&b,'"')
        escaped,_:=strings.replace_all(word,"\"","\"\"",context.temp_allocator)
        strings.write_string(&b,escaped)
        strings.write_byte(&b,'"')
    }
    return strings.to_string(b),true
}
search_result :: proc(s:^Store,c:json.Object,payload:string,now:i64,kr:^vault.Vault_Keyring)->Result {
    p,valid:=contracts.owner_parse(payload,"search_payload")
    if !valid do return fail("malformed")
    text,opened:=vault.open(field(p,"query_cipher"),kr,context.temp_allocator)
    if opened!=.Ok do return fail("invalid_content")
    literal,ok:=search_literal(text)
    limit:=number(field(p,"limit"))
    if !ok || limit<1 || limit>SEARCH_MAX_HITS do return fail("malformed")
    if !s.search_ready do return fail("storage_error")
    budget:=SEARCH_VM_BUDGET
    sqlite3_progress_handler(s.db,1000,search_budget,&budget)
    defer sqlite3_progress_handler(s.db,0,nil,nil)
    // Materialize authorization before MATCH/snippet extraction.
    rows,queried:=query(s.db,`WITH allowed AS MATERIALIZED (
      SELECT d.* FROM search_docs d JOIN local_grants g ON g.chain_id=d.chain_id
      WHERE d.chain_id=? AND g.principal_id=? AND g.key_id=? AND g.can_read=1
        AND g.revoked=0 AND g.expires_ms>?
    )
    SELECT d.chain_id,d.task_id,d.kind,d.object_id,d.revision,
           d.title,snippet(search_fts,1,'','',' … ',24)
    FROM allowed d JOIN search_fts ON search_fts.rowid=d.rowid
    WHERE search_fts MATCH ? ORDER BY d.kind,d.object_id LIMIT ?`,
      field(c,"chain_id"),field(c,"principal_id"),field(c,"key_id"),fmt.tprintf("%d",now),literal,fmt.tprintf("%d",limit))
    if !queried do return fail("storage_error")
    state,read:=query(s.db,"SELECT commit_seq FROM runtime_database WHERE singleton=1")
    if !read || len(state)!=1 do return fail("storage_error")
    items:=make([dynamic]json.Value,context.temp_allocator)
    result:=make(json.Object,context.temp_allocator)
    result["indexed_seq"]=json.String(state[0][0])
    result["revision"]=json.String("0")
    for row in rows {
        append(&items,doc(map[string]string{"chain_id"=row[0],"task_id"=row[1],"kind"=row[2],"object_id"=row[3],"object_revision"=row[4],"title"=row[5],"description"=row[6]}))
        result["hits"]=json.Array(items)
        if len(encode(result))>MAX_PAGE {
            ordered_remove(&items,len(items)-1)
            break
        }
    }
    result["hits"]=json.Array(items)
    return Result{code="ok",body=encode(result),seq=number(state[0][0])}
}

// Startup rebuild uses canonical rows and never raw-deletes FTS shadow tables.
search_rebuild :: proc(s:^Store)->bool {
    sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
    s.search_ready=false
    if !exec(s.db,"BEGIN IMMEDIATE") do return false
    committed:=false
    defer {if !committed do _=exec(s.db,"ROLLBACK")}
    if !exec(s.db,`INSERT INTO search_fts(search_fts) VALUES('rebuild');
      DELETE FROM search_docs;
      INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
        SELECT chain_id,'','chain',chain_id,revision,title,description FROM task_chains;
      INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
        SELECT chain_id,task_id,'task',task_id,revision,title,body FROM tasks;
      INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
        SELECT chain_id,task_id,'comment',principal_id||':'||operation_id,seq,'',body FROM task_comments;
      INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
        SELECT chain_id,task_id,'requirements',task_id,revision,'',brief_json FROM task_requirements a
        WHERE revision=(SELECT MAX(b.revision) FROM task_requirements b WHERE b.chain_id=a.chain_id AND b.task_id=a.task_id);
      INSERT INTO search_docs(chain_id,task_id,kind,object_id,revision,title,body)
        SELECT chain_id,task_id,'output',task_id,attempt,'',summary FROM local_submissions a
        WHERE attempt=(SELECT MAX(b.attempt) FROM local_submissions b WHERE b.chain_id=a.chain_id AND b.task_id=a.task_id);
      INSERT INTO search_fts(search_fts,rank) VALUES('integrity-check',1);
      COMMIT;`) { return false }
    committed=true
    s.search_ready=true
    return true
}
