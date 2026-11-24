package actions

import "core:encoding/json"
import "core:slice"
import "core:strings"

// Every admitted object belongs to this projection. Sizes include braces,
// commas, escaped keys and escaped values, so admission never serializes the
// growing snapshot. Borrowed leaves are immutable until the final marshal.
Snapshot_Node :: struct {
 object:bool,
 children:map[string]^Snapshot_Node,
 value:json.Value,
 size:int,
}
snapshot_node :: proc(value:json.Value)->^Snapshot_Node {
 node:=new(Snapshot_Node,context.temp_allocator)
 if object,ok:=value.(json.Object);ok {
  node.object=true
  node.children=make(map[string]^Snapshot_Node,context.temp_allocator)
  node.size=2
  for key,item in object {
   child:=snapshot_node(item)
   node.size+=snapshot_entry_size(key,child.size,len(node.children)>0)
   node.children[key]=child
  }
 } else {node.value=value;node.size=len(snapshot_encode(value))}
 return node
}
snapshot_entry_size :: proc(key:string,value_bytes:int,comma:bool)->int {
 return len(snapshot_encode(key))+1+value_bytes+(1 if comma else 0)
}
// Return the exact delta without mutation, or apply that same delta. Existing
// paths have higher priority than a later parent-path request.
snapshot_merge_delta :: proc(old,next:^Snapshot_Node,commit:bool)->int {
 if !old.object || !next.object do return 0
 delta:=0
 count:=len(old.children)
 for key,child in next.children {
  previous,exists:=old.children[key]
  if exists {delta+=snapshot_merge_delta(previous,child,commit)} else {
   delta+=snapshot_entry_size(key,child.size,count>0);count+=1
   if commit do old.children[key]=child
  }
 }
 if commit do old.size+=delta
 return delta
}
snapshot_path_delta :: proc(root:^Snapshot_Node,path:[]string,value:^Snapshot_Node,commit:bool)->int {
 if !root.object do return 0
 child,exists:=root.children[path[0]]
 delta:=0
 if exists {
  if len(path)==1 {delta=snapshot_merge_delta(child,value,commit)} else {delta=snapshot_path_delta(child,path[1:],value,commit)}
 } else {
  size:=value.size
  for i:=len(path)-1;i>0;i-=1 do size=2+snapshot_entry_size(path[i],size,false)
  delta=snapshot_entry_size(path[0],size,len(root.children)>0)
  if commit {
   child=value
   for i:=len(path)-1;i>0;i-=1 {
    parent:=snapshot_node(json.Object{})
    parent.children[path[i]]=child
    parent.size+=snapshot_entry_size(path[i],child.size,false)
    child=parent
   }
   root.children[path[0]]=child
  }
 }
 if commit do root.size+=delta
 return delta
}
snapshot_node_value :: proc(node:^Snapshot_Node)->json.Value {
 if !node.object do return node.value
 object:=make(json.Object,context.temp_allocator)
 for key,child in node.children do object[key]=snapshot_node_value(child)
 return object
}
snapshot_keys :: proc(object:json.Object)->[]string {
 keys:=make([]string,len(object),context.temp_allocator)
 i:=0
 for key in object {keys[i]=key;i+=1}
 slice.sort(keys)
 return keys
}

// A linked list removes an admitted path in O(1). Measuring the bounded prefix
// examines at most 33 nodes and allocates nothing, even at 4096 template paths.
Snapshot_Omission :: struct {field:string,bytes,previous,next:int}
Snapshot_Omissions :: struct {items:[dynamic]Snapshot_Omission,head,tail,count:int}
snapshot_omission_add :: proc(s:^Snapshot_Omissions,field:string)->int {
 index:=len(s.items)
 append(&s.items,Snapshot_Omission{field=field,bytes=len(snapshot_encode(field)),previous=s.tail,next=-1})
 if s.tail>=0 {s.items[s.tail].next=index} else {s.head=index}
 s.tail=index;s.count+=1
 return index
}
snapshot_omission_remove :: proc(s:^Snapshot_Omissions,index:int) {
 item:=s.items[index]
 if item.previous>=0 {s.items[item.previous].next=item.next} else {s.head=item.next}
 if item.next>=0 {s.items[item.next].previous=item.previous} else {s.tail=item.previous}
 s.count-=1
}
snapshot_digits :: proc(n:int)->int {
 result:=1
 for number:=n;number>=10;number/=10 do result+=1
 return result
}
snapshot_omission_delta :: proc(s:^Snapshot_Omissions,total:int,exclude:=-1)->int {
 bytes,count:=2,0
 for i:=s.head;i>=0;i=s.items[i].next {
  if i==exclude do continue
  item:=s.items[i]
  if count==32 || bytes+item.bytes+(1 if count>0 else 0)>total/3 do break
  bytes+=item.bytes+(1 if count>0 else 0);count+=1
 }
 return bytes-2+snapshot_digits(s.count-(1 if exclude>=0 else 0))-1
}
snapshot_omission_values :: proc(s:^Snapshot_Omissions,total:int)->json.Array {
 list:=make(json.Array,0,32,context.temp_allocator)
 bytes:=2
 for i:=s.head;i>=0;i=s.items[i].next {
  item:=s.items[i]
  if len(list)==32 || bytes+item.bytes+(1 if len(list)>0 else 0)>total/3 do break
  bytes+=item.bytes+(1 if len(list)>0 else 0)
  append(&list,json.Value(item.field))
 }
 return list
}

snapshot_project :: proc(header,envelope:json.Object,p:Snapshot_Projection,limits:Snapshot_Limits)->string {
 l:=snapshot_limits(limits)
 params:=header
 params["_value_bytes"]=json.Integer(l.value_bytes)
 params["data"]=json.Object{}
 params["_omitted"]=make(json.Array,0,0,context.temp_allocator)
 params["_omitted_count"]=json.Integer(0)
 base:=len(snapshot_encode(params))
 root:=snapshot_node(json.Object{})
 omissions:=Snapshot_Omissions{head=-1,tail=-1,items=make([dynamic]Snapshot_Omission,0,len(p.paths)+33,context.temp_allocator)}
 // Count the unlisted overflow as well as the bounded list retained at compile.
 omissions.count=p.overflow_count-len(p.overflow_paths)
 indices:=make([]int,len(p.paths),context.temp_allocator)
 paths:=make([][]string,len(p.paths),context.temp_allocator)
 values:=make([]json.Value,len(p.paths),context.temp_allocator)
 requested_top:=make(map[string]bool,context.temp_allocator)
 for field,i in p.paths {
  indices[i]=-1
  path:=strings.split(field,".",context.temp_allocator)
  paths[i]=path[1:]
  requested_top[path[1]]=true
  value,present:=snapshot_lookup(envelope,path)
  if !present do continue
  indices[i]=snapshot_omission_add(&omissions,field)
  values[i]=value
 }
 for field in p.overflow_paths do _=snapshot_omission_add(&omissions,field)
 json_omission:=-1
 if p.event_json do json_omission=snapshot_omission_add(&omissions,"event.json")
 for _,i in p.paths {
  if indices[i]<0 do continue
  value:=snapshot_node(snapshot_value(values[i],l.value_bytes))
  delta:=snapshot_path_delta(root,paths[i],value,false)
  size:=base+root.size-2+delta+snapshot_omission_delta(&omissions,l.total_bytes,indices[i])
  if size>l.total_bytes do continue
  _=snapshot_path_delta(root,paths[i],value,true)
  snapshot_omission_remove(&omissions,indices[i])
 }
 source,_:=envelope["data"].(json.Object)
 json_cost:=0
 if p.event_json {
  encoded:=snapshot_encode(source)
  remaining:=l.total_bytes-base-(root.size-2)-snapshot_omission_delta(&omissions,l.total_bytes,json_omission)
  candidate:=encoded
  // Cost includes the outer JSON string's escaping, not only body bytes.
  cost:=snapshot_entry_size("json",len(snapshot_encode(candidate)),true)
  if len(candidate)>l.json_bytes || cost>remaining {
   fallback:=make(json.Object,context.temp_allocator)
   fallback["_truncated"]=true;fallback["bytes"]=json.Integer(len(encoded))
   keys:=make(json.Array,0,32,context.temp_allocator)
   key_bytes:=0
   for key in snapshot_keys(source) {
    bytes:=len(snapshot_encode(key))
    if len(keys)==32 || key_bytes+bytes>l.json_bytes/2 do break
    append(&keys,json.Value(key));key_bytes+=bytes+1
   }
   for {
    fallback["keys"]=keys
    candidate=snapshot_encode(fallback)
    cost=snapshot_entry_size("json",len(snapshot_encode(candidate)),true)
    if len(candidate)<=l.json_bytes && cost<=remaining do break
    if len(keys)==0 {candidate="";break}
    // Geometric shrinking bounds work even with large configured limits.
    resize(&keys,len(keys)/2)
   }
  }
  if candidate!="" {
   params["json"]=candidate;json_cost=cost
   snapshot_omission_remove(&omissions,json_omission)
  }
 }
 // Top-level scalar fill is linear in the body key count and snapshot size.
 // No map copying or growing-snapshot marshal occurs inside this loop.
 if p.overflow_count==0 {
  for key in snapshot_keys(source) {
   remaining:=l.total_bytes-base-(root.size-2)-json_cost-snapshot_omission_delta(&omissions,l.total_bytes)
   if remaining<5 do break
   if _,exists:=root.children[key];exists do continue
   if requested_top[key] do continue
   text,scalar:=scalar_text(source[key])
   if !scalar || len(text)>256 do continue
   value:=snapshot_node(source[key])
   path:=[1]string{key}
   delta:=snapshot_path_delta(root,path[:],value,false)
   if delta<=remaining do _=snapshot_path_delta(root,path[:],value,true)
  }
 }
 params["data"]=snapshot_node_value(root)
 params["_omitted"]=snapshot_omission_values(&omissions,l.total_bytes)
 params["_omitted_count"]=json.Integer(omissions.count)
 return snapshot_encode(params)
}
