package actions

import "core:encoding/json"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// All index storage lives outside the per-batch scratch arena. Only the matcher
// thread touches it; writers publish invalidation through Service.rule_epoch.
Compiled_Rule :: struct {
 trigger: domain.Action_Trigger,
 tree: Compiled_Filter,
 projection: Snapshot_Projection,
 subject_tokens: []string,
 updated_at_ms: i64,
}
Rule_Bucket :: struct {exact:map[string][dynamic]int, wild:[dynamic]int}
Owner_Rules :: struct {rules:[]Compiled_Rule, events:map[string]^Rule_Bucket}
Rule_Index :: struct {
 arena:virtual.Arena,
 initialized:bool,
 epoch:i64,
 owners:map[string]^Owner_Rules,
}
rule_index_clear :: proc(index:^Rule_Index) {
 if index.initialized do virtual.arena_destroy(&index.arena)
 index^={}
}
rule_index_sync :: proc(r:^Runtime) {
 epoch:=sync.atomic_load(&r.svc.rule_epoch)
 if r.rule_index.initialized && r.rule_index.epoch!=epoch do rule_index_clear(&r.rule_index)
}
rule_index_owner :: proc(r:^Runtime,repo:^iface.Action_Repository,owner:string)->(^Owner_Rules,domain.Domain_Error) {
 rule_index_sync(r)
 index:=&r.rule_index
 if !index.initialized {
  if virtual.arena_init_growing(&index.arena)!=nil do return nil,domain.domain_error(.Internal_Error,"rule cache unavailable")
  index.initialized=true
  index.epoch=sync.atomic_load(&r.svc.rule_epoch)
  index.owners=make(map[string]^Owner_Rules,virtual.arena_allocator(&index.arena))
 }
 if cached,found:=index.owners[owner];found do return cached,{}
 context.allocator=virtual.arena_allocator(&index.arena)
 rows,err:=repo.projection_rules_owner(repo.ctx,owner)
 if err.code!=.None do return nil,err
 cached:=new(Owner_Rules)
 cached.rules=make([]Compiled_Rule,len(rows))
 cached.events=make(map[string]^Rule_Bucket)
 for row,i in rows {
  trigger:=row.trigger
  if string(trigger.owner_user_id)!=owner || !trigger.enabled do continue
  updated,valid:=platform.rfc3339_to_unix_ms(trigger.updated_at)
  if !valid do continue
  value:json.Value
  raw:=trigger.data_filter_json
  if raw=="" do raw="{}"
  if json.unmarshal(transmute([]u8)raw,&value,allocator=context.temp_allocator)!=nil do continue
  tree,e:=filter_compile(value,nil,FILTER_READ_LIMITS,context.allocator)
  json.destroy_value(value,allocator=context.temp_allocator)
  if e.reason!="" do continue
  projection:=snapshot_projection(tree,row.prompt_text,context.allocator,r.svc.snapshot_limits)
  cached.rules[i]={trigger=trigger,tree=tree,projection=projection,updated_at_ms=updated}
  bucket,exists:=cached.events[trigger.event_type]
  if !exists {
   bucket=new(Rule_Bucket)
   bucket.exact=make(map[string][dynamic]int)
   cached.events[trigger.event_type]=bucket
  }
  if !strings.contains(trigger.subject_filter,"*") {
   entries:=bucket.exact[trigger.subject_filter]
   append(&entries,i)
   bucket.exact[trigger.subject_filter]=entries
  } else {
   cached.rules[i].subject_tokens=strings.split(trigger.subject_filter,".")
   append(&bucket.wild,i)
  }
 }
 index.owners[strings.clone(owner)]=cached
 return cached,{}
}
rule_subject_matches :: proc(filter,subject:[]string)->bool {
 if len(filter)!=len(subject) do return false
 for token,i in filter do if token!="*" && token!=subject[i] do return false
 return true
}
