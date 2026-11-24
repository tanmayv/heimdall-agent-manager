package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"

Snapshot_Limits :: struct {total_bytes, value_bytes, json_bytes, template_paths:int}
SNAPSHOT_DEFAULT_LIMITS :: Snapshot_Limits{8192,2048,4096,64}
snapshot_limits :: proc(l:Snapshot_Limits)->Snapshot_Limits {
 return SNAPSHOT_DEFAULT_LIMITS if l==Snapshot_Limits{} else l
}
snapshot_limits_valid :: proc(l:Snapshot_Limits)->bool {
 return l.total_bytes>=1024 && l.total_bytes<=1048576 && l.value_bytes>=128 && l.value_bytes<=l.total_bytes && l.json_bytes>=128 && l.json_bytes<=l.total_bytes && l.template_paths>=1 && l.template_paths<=4096
}
Snapshot_Projection :: struct {paths,overflow_paths:[]string, overflow_count:int, event_json:bool}
// Filter paths precede template paths. Storage belongs to the rule-index arena.
snapshot_projection :: proc(tree:Compiled_Filter,prompt:string,allocator:mem.Allocator,limits:=Snapshot_Limits{})->Snapshot_Projection {
 paths:=make([dynamic]string,0,0,allocator)
 overflow:=make([dynamic]string,0,0,allocator)
 overflow_count,template_count:=0,0
 seen:=make(map[string]bool,context.temp_allocator)
 for node in tree.nodes {
  if node.kind==.Check && strings.has_prefix(node.field,"data.") && !seen[node.field] {
   append(&paths,strings.clone(node.field,allocator));seen[node.field]=true
  }
 }
 wants_json:=false
 for pos:=0;pos<len(prompt); {
  left:=strings.index(prompt[pos:],"{{")
  if left<0 do break
  left+=pos
  right:=strings.index(prompt[left+2:],"}}")
  if right<0 do break
  right+=left+2
  key:=strings.trim_space(prompt[left+2:right]);pos=right+2
  if key=="event.json" do wants_json=true
  if !strings.has_prefix(key,"event.data.") do continue
  field:=key[len("event."):]
  if !filter_field_valid(field,nil,FILTER_READ_LIMITS) || seen[field] do continue
  seen[field]=true
  if template_count>=snapshot_limits(limits).template_paths {
   overflow_count+=1
   if len(overflow)<32 do append(&overflow,strings.clone(field,allocator))
   continue
  }
  template_count+=1
  append(&paths,strings.clone(field,allocator))
 }
 return {paths=paths[:],overflow_paths=overflow[:],overflow_count=overflow_count,event_json=wants_json}
}
snapshot_encode :: proc(value:json.Value)->string {
 bytes,_:=json.marshal(value,opt={sort_maps_by_key=true},allocator=context.temp_allocator)
 return string(bytes)
}
// Keep a valid UTF-8 prefix, including space for the explicit truncation marker.
snapshot_text :: proc(text:string,limit:int)->string {
 if len(text)<=limit do return text
 end:=max(0,limit-40)
 for end>0 && (text[end]&0xc0)==0x80 do end-=1
 return fmt.tprintf("%s…[truncated %d bytes]",text[:end],len(text)-end)
}
snapshot_value :: proc(value:json.Value,limit:int)->json.Value {
 if text,ok:=value.(string);ok do return snapshot_text(text,limit)
 encoded:=snapshot_encode(value)
 if len(encoded)<=limit do return value
 marker:=make(json.Object,context.temp_allocator)
 marker["_truncated"]=true;marker["bytes"]=json.Integer(len(encoded))
 return marker
}
snapshot_lookup :: proc(root:json.Object,path:[]string)->(json.Value,bool) {
 value:=json.Value(root)
 for segment in path {
  object,ok:=value.(json.Object)
  if !ok do return json.Null{},false
  next,present:=object[segment]
  if !present do return json.Null{},false
  value=next
 }
 return value,true
}
