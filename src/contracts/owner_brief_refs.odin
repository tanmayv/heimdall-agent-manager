package contracts

import "core:strings"

// String vocabulary shared with native task briefs. Mutable "latest output"
// and path lookups are intentionally outside this local immutable boundary.
Owner_Pinned_Ref :: struct { kind,task,attempt,version,key:string }
owner_pinned_ref :: proc(raw:string) -> (Owner_Pinned_Ref,bool) {
    if len(raw)>512 || strings.trim_space(raw)!=raw do return {},false
    if strings.has_prefix(raw,"#") {
        key:=raw[1:]
        return Owner_Pinned_Ref{kind="event",key=key},owner_field_valid(key,"positive")
    }

    parts:=strings.split(raw,":",context.temp_allocator)
    n:=len(parts)
    if n<4 do return {},false
    if parts[0]=="output" {
        task:=strings.join(parts[1:n-2],":",context.temp_allocator)
        if !owner_field_valid(task,"id") || !owner_field_valid(parts[n-2],"positive") || !owner_field_valid(parts[n-1],"positive") do return {},false
        return Owner_Pinned_Ref{kind="facet",task=task,attempt=parts[n-2],key="output",version=parts[n-1]},true
    }
    if parts[0]!="facet" do return {},false
    kind_index:=n-1
    version:=""
    if !owner_field_valid(parts[kind_index],"facet_kind") {
        version=parts[n-1];kind_index-=1
        if n<5 || !owner_field_valid(version,"positive") do return {},false
    }
    task:=strings.join(parts[1:kind_index-1],":",context.temp_allocator)
    attempt,key:=parts[kind_index-1],parts[kind_index]
    if !owner_field_valid(task,"id") || !owner_field_valid(key,"facet_kind") || !owner_field_valid(attempt,"counter" if key=="placement" else "positive") do return {},false
    // A versionless native spelling requires a unique version at admission.
    return Owner_Pinned_Ref{kind="facet",task=task,attempt=attempt,key=key,version=version},true
}
