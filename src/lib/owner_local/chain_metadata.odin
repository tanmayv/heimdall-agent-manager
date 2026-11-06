#+feature dynamic-literals
package owner_local

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"

// Authorized by execute before any row is read. History remains immutable;
// cursors are bound to the exact observed chain revision.
chain_metadata_read :: proc(s:^Store,chain:string,p:json.Object,revision:i64) -> Result {
    scope:=contracts.owner_payload_digest(encode([3]string{s.account,chain,fmt.tprintf("%d",revision)}))
    offset:i64
    cursor:=field(p,"cursor")
    if cursor!="" {
        parts:=strings.split(cursor,":",context.temp_allocator)
        if len(parts)!=2 || parts[0]!=scope do return fail("stale_cursor")
        offset=number(parts[1])
        if offset<0 || fmt.tprintf("%d",offset)!=parts[1] do return fail("malformed")
    }
    // At most three maximum-size prose records fit the fixed response budget.
    limit:=min(number(field(p,"limit")),3)
    rows,ok:=query(s.db,"SELECT kind,accepted_seq,body,entity_id,enabled,current FROM (SELECT 'summary' kind,accepted_seq,curated_body body,'' entity_id,'' enabled,accepted_seq=(SELECT max(accepted_seq) FROM local_chain_summary_versions WHERE chain_id=?1) current FROM local_chain_summary_versions WHERE chain_id=?1 UNION ALL SELECT 'defaults',accepted_seq,defaults_json,'','',accepted_seq=(SELECT max(accepted_seq) FROM local_chain_defaults_versions WHERE chain_id=?1) FROM local_chain_defaults_versions WHERE chain_id=?1 UNION ALL SELECT 'member',accepted_seq,json_object('instance_id',instance_id,'agent_id',agent_id,'role',role),instance_id,enabled,accepted_seq=(SELECT max(accepted_seq) FROM local_chain_member_versions x WHERE x.chain_id=m.chain_id AND x.instance_id=m.instance_id) FROM local_chain_member_versions m WHERE chain_id=?1 UNION ALL SELECT 'directory',accepted_seq,body,directory_id,enabled,accepted_seq=(SELECT max(accepted_seq) FROM local_chain_directory_versions x WHERE x.chain_id=d.chain_id AND x.directory_id=d.directory_id) FROM local_chain_directory_versions d WHERE chain_id=?1) ORDER BY accepted_seq DESC,kind,entity_id LIMIT ?2 OFFSET ?3",chain,fmt.tprintf("%d",limit+1),fmt.tprintf("%d",offset))
    if !ok do return fail("storage_error")
    next:=""
    if len(rows)>int(limit) {next=fmt.tprintf("%s:%d",scope,offset+limit)}
    items:=make([dynamic]json.Object,context.temp_allocator)
    for row in rows[:min(len(rows),int(limit))] {
        item:=doc(map[string]string{"kind"=row[0],"accepted_seq"=row[1]})
        item["curated_body" if row[0]=="summary" else ("defaults_json" if row[0]=="defaults" else "body")]=json.String(row[2])
        item["entity_id"]=json.String(row[3]);item["enabled"]=json.String(row[4]);item["current"]=json.String(row[5])
        append(&items,item)
    }
    body:=encode(struct {revision:string,items:[dynamic]json.Object,next_cursor:string,}{fmt.tprintf("%d",revision),items,next})
    if len(body)>MAX_PAGE do return fail("invalid_content")
    return Result{code="ok",body=body}
}
