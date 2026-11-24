package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:slice"

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
// Copy only the object spine; never mutate the full event or an admitted value.
snapshot_set :: proc(object:json.Object,path:[]string,value:json.Value)->json.Object {
 copy:=make(json.Object,context.temp_allocator)
 for key,item in object do copy[key]=item
 if len(path)==1 {
  previous,exists:=copy[path[0]]
  if exists {copy[path[0]]=snapshot_merge(previous,value)} else {copy[path[0]]=value}
  return copy
 }
 child,_:=object[path[0]].(json.Object)
 copy[path[0]]=snapshot_set(child,path[1:],value)
 return copy
}
// A later parent-path request must never erase a higher-priority child.
snapshot_merge :: proc(previous,next:json.Value)->json.Value {
 old,old_object:=previous.(json.Object)
 added,new_object:=next.(json.Object)
 if !old_object || !new_object do return previous
 merged:=make(json.Object,context.temp_allocator)
 for key,value in added do merged[key]=value
 for key,value in old {
  if child,exists:=merged[key];exists {merged[key]=snapshot_merge(value,child)} else {merged[key]=value}
 }
 return merged
}
snapshot_keys :: proc(object:json.Object)->[]string {
 keys:=make([]string,len(object),context.temp_allocator)
 i:=0
 for key in object {keys[i]=key;i+=1}
 slice.sort(keys)
 return keys
}
snapshot_omissions :: proc(params:^json.Object,paths:[]string,extra,total:int,exclude:="") {
 list:=make(json.Array,0,32,context.temp_allocator)
 count:=extra
 for path in paths {
  if path==exclude do continue
  count+=1
  if len(list)>=32 do continue
  append(&list,json.Value(path))
  if len(snapshot_encode(list))>total/3 do resize(&list,len(list)-1)
 }
 params^["_omitted"]=list
 params^["_omitted_count"]=json.Integer(count)
}
// Budget the actual JSON encoding (escaping and nested key overhead included).
// Reserve omission bookkeeping before admitting values, so later omissions can
// never make an otherwise bounded snapshot overflow.
snapshot_project :: proc(header,envelope:json.Object,p:Snapshot_Projection,limits:Snapshot_Limits)->string {
 params:=header
 l:=snapshot_limits(limits)
 params["_value_bytes"]=json.Integer(l.value_bytes)
 data:=make(json.Object,context.temp_allocator)
 params["data"]=data
 omitted:=make([dynamic]string,0,len(p.paths)+33,context.temp_allocator)
 for field in p.paths {
  _,present:=snapshot_lookup(envelope,strings.split(field,".",context.temp_allocator))
  if present do append(&omitted,field)
 }
 for field in p.overflow_paths do append(&omitted,field)
 extra:=p.overflow_count-len(p.overflow_paths)
 if p.event_json do append(&omitted,"event.json")
 snapshot_omissions(&params,omitted[:],extra,l.total_bytes)
 for field in p.paths {
  path:=strings.split(field,".",context.temp_allocator)
  original,present:=snapshot_lookup(envelope,path)
  if !present do continue
  candidate:=snapshot_set(data,path[1:],snapshot_value(original,l.value_bytes))
  params["data"]=candidate
  snapshot_omissions(&params,omitted[:],extra,l.total_bytes,field)
  if len(snapshot_encode(params))<=l.total_bytes {
   data=candidate
   for item,i in omitted do if item==field {ordered_remove(&omitted,i);break}
  } else {params["data"]=data;snapshot_omissions(&params,omitted[:],extra,l.total_bytes)}
 }
 source,_:=envelope["data"].(json.Object)
 if p.event_json {
  snapshot_omissions(&params,omitted[:],extra,l.total_bytes,"event.json")
  encoded:=snapshot_encode(source)
  fallback:=make(json.Object,context.temp_allocator)
  fallback["_truncated"]=true;fallback["bytes"]=json.Integer(len(encoded))
  keys:=make(json.Array,0,len(source),context.temp_allocator)
  for key in snapshot_keys(source) do append(&keys,json.Value(key))
  fallback["keys"]=keys
  candidate:=encoded
  for {
   params["json"]=candidate
   if len(candidate)<=l.json_bytes && len(snapshot_encode(params))<=l.total_bytes do break
   candidate=snapshot_encode(fallback)
   params["json"]=candidate
   if len(candidate)<=l.json_bytes && len(snapshot_encode(params))<=l.total_bytes do break
   if len(keys)==0 {delete_key(&params,"json");break}
   resize(&keys,len(keys)-1);fallback["keys"]=keys
  }
  if _,present:=params["json"];present {
   for item,i in omitted do if item=="event.json" {ordered_remove(&omitted,i);break}
  }
  snapshot_omissions(&params,omitted[:],extra,l.total_bytes)
 }
 // Small top-level scalars are useful context, but never displace referenced
 // paths or event.json. Sorted admission keeps output deterministic.
 for key in snapshot_keys(source) {
  if p.overflow_count>0 do break
  if _,exists:=data[key];exists do continue
  text,scalar:=scalar_text(source[key])
  if !scalar || len(text)>256 do continue
  field:=fmt.tprintf("data.%s",key)
  requested:=false
  for path in p.paths do if path==field || strings.has_prefix(path,fmt.tprintf("%s.",field)) do requested=true
  if requested do continue
  candidate:=snapshot_set(data,[]string{key},source[key])
  params["data"]=candidate
  if len(snapshot_encode(params))<=l.total_bytes {data=candidate} else {params["data"]=data}
 }
 return snapshot_encode(params)
}
