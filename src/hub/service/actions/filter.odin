package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

Filter_Limits :: contracts.Action_Filter_Limits
FILTER_DEFAULT_LIMITS :: contracts.ACTION_FILTER_DEFAULT_LIMITS
FILTER_OPERATORS := []string{"eq","ne","in","not_in","exists","prefix"}
Filter_Node_Kind :: enum {All, Any, Not, Check}
Filter_Node :: struct {
 kind: Filter_Node_Kind,
 field, op: string,
 path: []string, // slices borrow field; split once at compilation
 children: []int, // evaluation order; node indices retain author trace order
 values: []string,
 exists: bool,
 end: int, // exclusive subtree end; nodes are in author pre-order
}
Compiled_Filter :: struct { nodes: [dynamic]Filter_Node }
Filter_Error :: struct {path, reason: string}
Filter_Builder :: struct {
 tree: Compiled_Filter,
 descriptor: ^Event_Descriptor,
 limits: Filter_Limits,
 checks: int,
 allocator: mem.Allocator,
}
filter_limits :: proc(limits: Filter_Limits) -> Filter_Limits {
 if limits == (Filter_Limits{}) do return FILTER_DEFAULT_LIMITS
 return limits
}
filter_limits_valid :: proc(l: Filter_Limits) -> bool {
 return l.max_depth >= 1 && l.max_depth <= 64 && l.max_checks >= 1 && l.max_checks <= 4096 &&
 l.max_nodes >= 1 && l.max_nodes <= 8192 && l.max_children >= 1 && l.max_children <= 4096 &&
 l.max_values >= 1 && l.max_values <= 4096 && l.max_value_bytes >= 1 && l.max_value_bytes <= 65536 &&
 l.max_field_bytes >= 1 && l.max_field_bytes <= 4096 && l.max_path_segments >= 1 && l.max_path_segments <= 64 &&
 l.max_segment_bytes >= 1 && l.max_segment_bytes <= 256 && l.max_bytes >= 2 && l.max_bytes <= 1048576
}
filter_error :: proc(e: Filter_Error) -> domain.Domain_Error {
 bytes,_ := json.marshal(struct{code,path,reason:string}{"invalid_filter",e.path,e.reason},allocator=context.temp_allocator)
 return domain.domain_error(.Validation_Failed,"invalid_filter",string(bytes))
}
filter_destroy :: proc(tree: ^Compiled_Filter, allocator := context.allocator) {
 for node in tree.nodes {
  delete(node.field,allocator); delete(node.op,allocator)
  delete(node.path,allocator); delete(node.children,allocator)
  for value in node.values do delete(value,allocator)
  delete(node.values,allocator)
 }
 delete(tree.nodes); tree^={}
}
filter_scalar :: proc(value: json.Value, allocator: mem.Allocator) -> (string,bool) {
 #partial switch v in value {
 case string: return strings.clone(v,allocator),true
 case json.Integer,json.Float,bool:
  bytes,err:=json.marshal(value,allocator=allocator)
  return string(bytes),err==nil
 case: return "",false
 }
}
filter_field_valid :: proc(field: string, d: ^Event_Descriptor, l: Filter_Limits) -> bool {
 if len(field)>l.max_field_bytes do return false
 if field=="entity.id" || field=="entity.kind" || field=="actor" do return true
 if !strings.has_prefix(field,"data.") do return false
 segments:=strings.split(field[len("data."):],".",context.temp_allocator)
 if len(segments)>l.max_path_segments do return false
 for segment in segments {
  if len(segment)==0 || len(segment)>l.max_segment_bytes do return false
  for c in transmute([]u8)segment {
   if !((c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-') do return false
  }
 }
 if d==nil || d.free_data_paths do return true
 if len(segments)!=1 do return false
 for key in d.data_keys do if key.key==segments[0] do return true
 return false
}
filter_add :: proc(b:^Filter_Builder, value:json.Value, path:string, depth:int) -> Filter_Error {
 if depth>b.limits.max_depth do return {path,"too_deep"}
 if len(b.tree.nodes)>=b.limits.max_nodes do return {path,"too_many_nodes"}
 obj,ok:=value.(json.Object)
 if !ok || len(obj)==0 do return {path,"unknown_node"}
 index:=len(b.tree.nodes)
 append(&b.tree.nodes,Filter_Node{})
 for key,k in ([]string{"all","any","not"}) {
  kind:=Filter_Node_Kind(k)
  raw,found:=obj[key]
  if !found do continue
  if len(obj)!=1 do return {path,"unknown_node"}
  b.tree.nodes[index].kind=kind
  if kind==.Not {
   if e:=filter_add(b,raw,fmt.tprintf("%s/not",path),depth+1);e.reason!="" do return e
  } else {
   children,valid:=raw.(json.Array)
   if !valid do return {path,"unknown_node"}
   if len(children)==0 do return {path,"empty_group"}
   if len(children)>b.limits.max_children do return {path,"too_many_nodes"}
   order:=make([]int,len(children),b.allocator)
   b.tree.nodes[index].children=order
   for child,i in children {
    order[i]=len(b.tree.nodes)
    if e:=filter_add(b,child,fmt.tprintf("%s/%s/%d",path,key,i),depth+1);e.reason!="" do return e
   }
   // Stable insertion sort: cheap checks before nested groups, without moving
   // the author-ordered node array used for traces.
   for i:=1;i<len(order);i+=1 {
    child:=order[i];j:=i
    for j>0 && filter_cost(b.tree.nodes[child])<filter_cost(b.tree.nodes[order[j-1]]) {
     order[j]=order[j-1];j-=1
    }
    order[j]=child
   }
  }
  b.tree.nodes[index].end=len(b.tree.nodes)
  return {}
 }
 if len(obj)!=3 do return {path,"unknown_node"}
 field,field_ok:=obj["field"].(string)
 op,op_ok:=obj["op"].(string)
 raw,has_value:=obj["value"]
 if !field_ok || !op_ok || !has_value do return {path,"unknown_node"}
 if !filter_field_valid(field,b.descriptor,b.limits) do return {path,"unknown_field"}
 known:=false
 for candidate in FILTER_OPERATORS do if op==candidate do known=true
 if !known do return {path,"unknown_op"}
 b.checks+=1
 if b.checks>b.limits.max_checks do return {path,"too_many_nodes"}
 node:=&b.tree.nodes[index]
 node.kind=.Check;node.end=index+1
 node.field=strings.clone(field,b.allocator);node.op=strings.clone(op,b.allocator)
 node.path=strings.split(node.field,".",b.allocator)
 if op=="exists" {
  flag,valid:=raw.(bool)
  if !valid do return {path,"bad_value"}
  node.exists=flag
  return {}
 }
 source:[]json.Value
 one:=[1]json.Value{raw}
 if op=="in" || op=="not_in" {
  list,valid:=raw.(json.Array)
  if !valid || len(list)==0 || len(list)>b.limits.max_values do return {path,"bad_value"}
  source=list[:]
 } else {source=one[:]}
 if op=="prefix" {
  text,valid:=raw.(string)
  if !valid || text=="" do return {path,"bad_value"}
 }
 node.values=make([]string,len(source),b.allocator)
 for item,i in source {
  text,valid:=filter_scalar(item,b.allocator)
  node.values[i]=text
  if !valid || len(text)>b.limits.max_value_bytes do return {path,"bad_value"}
 }
 return {}
}
// Compilation owns every string and uses no repository or clock. Descriptor nil
// allows any syntactically valid data path (used for persisted, validated trees).
filter_compile :: proc(value:json.Value, descriptor:^Event_Descriptor, limits:Filter_Limits, allocator:=context.allocator) -> (Compiled_Filter,Filter_Error) {
 l:=filter_limits(limits)
 encoded,err:=json.marshal(value,allocator=context.temp_allocator)
 if err!=nil do return {},{"","unknown_node"}
 if len(encoded)>l.max_bytes do return {},{"","too_large"}
 if obj,ok:=value.(json.Object);ok && len(obj)==0 do return {},{}
 b:=Filter_Builder{descriptor=descriptor,limits=l,allocator=allocator}
 b.tree.nodes=make([dynamic]Filter_Node,0,0,allocator)
 if e:=filter_add(&b,value,"",1);e.reason!="" {filter_destroy(&b.tree,allocator);return {},e}
 return b.tree,{}
}
filter_cost :: proc(node:Filter_Node)->int {
 if node.kind!=.Check do return 4
 switch node.op {
 case "exists":return 0
 case "eq","ne":return 1
 case "prefix":return 2
 case:return 3
 }
}
filter_lookup :: proc(envelope:json.Object,path:[]string) -> json.Value {
 value:=json.Value(envelope)
 for segment in path {
  obj,ok:=value.(json.Object)
  if !ok do return json.Null{}
  value=obj[segment]
 }
 return value
}
filter_check :: proc(node:Filter_Node,envelope:json.Object) -> bool {
 actual:=filter_lookup(envelope,node.path)
 if node.op=="exists" {
  _,null:=actual.(json.Null)
  return (!null)==node.exists
 }
 if node.op=="prefix" {
  value,is_string:=actual.(string)
  return is_string && strings.has_prefix(value,node.values[0])
 }
 // JSON's own scalar writer preserves its exact numeric spelling. Its writer
 // fits in this stack buffer, so matching an already-compiled rule allocates
 // nothing, including for numeric or boolean event values.
 buffer:[128]u8
 builder:=strings.builder_from_slice(buffer[:])
 text,present:=actual.(string)
 if !present {
  #partial switch v in actual {
  case json.Integer,json.Float,bool:
   options:json.Marshal_Options
   present=json.marshal_to_builder(&builder,actual,&options)==nil
   text=strings.to_string(builder)
  }
 }
 equal:=false
 if present do for expected in node.values do if text==expected {equal=true;break}
 if node.op=="ne" || node.op=="not_in" do return !equal
 return equal
}
filter_eval_node :: proc(tree:Compiled_Filter,index:int,envelope:json.Object,trace:[]u8) -> bool {
 node:=tree.nodes[index]
 result:=false
 switch node.kind {
 case .Check: result=filter_check(node,envelope)
 case .Not: result=!filter_eval_node(tree,index+1,envelope,trace)
 case .All,.Any:
  result=node.kind==.All
  for child in node.children {
   matched:=filter_eval_node(tree,child,envelope,trace)
   if node.kind==.All {result=result && matched} else {result=result || matched}
   if len(trace)==0 && ((node.kind==.All && !result) || (node.kind==.Any && result)) do break
  }
 }
 if len(trace)>0 do trace[index]='T' if result else 'F'
 return result
}
filter_evaluate :: proc(tree:Compiled_Filter,envelope:json.Object,full_trace:=false,allocator:=context.allocator) -> (bool,string) {
 if len(tree.nodes)==0 do return true,""
 trace:[]u8
 if full_trace do trace=make([]u8,len(tree.nodes),allocator)
 return filter_eval_node(tree,0,envelope,trace),string(trace)
}
