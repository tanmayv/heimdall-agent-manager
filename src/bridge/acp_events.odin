package main

import "base:runtime"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"

ACP_Tool_State :: struct {
    id, name, kind, title, input, output, status, content: string,
    started, ended, payload_truncated: bool,
    diffs: [dynamic]string,
}

ACP_TOOLS_ACTIVE_MAX :: 512
ACP_TOOLS_RECENT_MAX :: 128
ACP_TOOLS_JOURNAL_MAX :: 2*1024*1024
ACP_Tool_Cache :: struct {
    entries:map[string]^ACP_Tool_State,
    recent:[dynamic]string,
    loaded,dirty:bool,
    bytes,active:int,
}

acp_tool_delete :: proc(tool:^ACP_Tool_State) {
    context.allocator=runtime.heap_allocator()
    for text in ([]string{tool.id,tool.name,tool.kind,tool.title,tool.input,tool.output,tool.status,tool.content}) {
        if text!="" do crypto.zero_explicit(raw_data(text),len(text))
        delete(text)
    }
    for digest in tool.diffs do delete(digest)
    delete(tool.diffs)
}

// A conservative JSON-size budget avoids serializing the map per update.
acp_tool_bytes :: proc(tool:^ACP_Tool_State) -> int {
    size:=512
    for text in ([]string{tool.id,tool.name,tool.kind,tool.title,tool.input,tool.output,tool.status,tool.content}) do size+=6*len(text)
    for digest in tool.diffs do size+=6*len(digest)+4
    return size
}

acp_tools_trim :: proc(cache:^ACP_Tool_Cache) {
    context.allocator=runtime.heap_allocator()
    for len(cache.recent)>0 && (len(cache.recent)>ACP_TOOLS_RECENT_MAX || cache.bytes>ACP_TOOLS_JOURNAL_MAX) {
        id:=cache.recent[0];ordered_remove(&cache.recent,0)
        tool:=cache.entries[id];delete_key(&cache.entries,id)
        cache.bytes-=acp_tool_bytes(tool);acp_tool_delete(tool);free(tool)
    }
}

acp_tool_clear :: proc(field:^string) {
    if field^!="" do crypto.zero_explicit(raw_data(field^),len(field^))
    acp_runtime_replace(field,"")
}

acp_tools_largest_open :: proc(cache:^ACP_Tool_Cache,stage:int) -> ^ACP_Tool_State {
    largest:^ACP_Tool_State;size:=0
    for _,tool in cache.entries {
        if tool.ended do continue
        bytes:=len(tool.content)+len(tool.output)
        if stage==1 do bytes=len(tool.input)
        if stage==2 do bytes=acp_tool_bytes(tool)
        if bytes>size { largest=tool;size=bytes }
    }
    return largest
}

// End bookkeeping once, even when the adapter omitted its terminal update.
// A later terminal update finds the compact receipt and cannot emit another end.
acp_tools_close :: proc(r:^ACP_Runtime,tool:^ACP_Tool_State,reason:string) {
    context.allocator=runtime.heap_allocator()
    if tool==nil || tool.ended do return
    before:=acp_tool_bytes(tool)
    if tool.started {
        native:=make(json.Object,allocator=context.temp_allocator)
        name:=tool.name;if name=="" do name=tool.kind;if name=="" do name=tool.title
        native["name"]=json.String(name);native["use_id"]=json.String(tool.id)
        native["input"]=make(json.Object,allocator=context.temp_allocator)
        payload:=make(json.Object,allocator=context.temp_allocator)
        payload["outcome"]=json.String("failure");payload["status"]=json.String("error");payload["stop_reason"]=json.String(reason)
        if tool.payload_truncated do payload["telemetry_truncated"]=json.Boolean(true)
        acp_events_emit(r,"tool.end",payload,native)
    }
    tool.ended=true;r.tools.active-=1
    for field in ([]^string{&tool.name,&tool.kind,&tool.title,&tool.input,&tool.output,&tool.status,&tool.content}) do acp_tool_clear(field)
    append(&r.tools.recent,tool.id)
    r.tools.bytes+=acp_tool_bytes(tool)-before;r.tools.dirty=true
}

// Telemetry pressure degrades optional cached detail; it never kills a prompt.
// Preserve dedupe/name/start state after discarding output/content, then input.
acp_tools_bound :: proc(r:^ACP_Runtime) {
    context.allocator=runtime.heap_allocator()
    cache:=&r.tools
    acp_tools_trim(cache)
    for stage in 0..<2 {
        for cache.bytes>ACP_TOOLS_JOURNAL_MAX {
            tool:=acp_tools_largest_open(cache,stage);if tool==nil do break
            before:=acp_tool_bytes(tool)
            if stage==0 { acp_tool_clear(&tool.content);acp_tool_clear(&tool.output) }
            else { acp_tool_clear(&tool.input) }
            tool.payload_truncated=true;cache.dirty=true
            cache.bytes+=acp_tool_bytes(tool)-before
        }
    }
    // Pathological metadata or too many concurrent tools still stay bounded.
    // Settle only their telemetry record, leaving the agent/RPC turn running.
    for cache.bytes>ACP_TOOLS_JOURNAL_MAX || cache.active>ACP_TOOLS_ACTIVE_MAX {
        tool:=acp_tools_largest_open(cache,2);if tool==nil do break
        acp_tools_close(r,tool,"telemetry_capacity")
        acp_tools_trim(cache)
    }
}

acp_tools_finish :: proc(r:^ACP_Runtime,reason:string) {
    context.allocator=runtime.heap_allocator()
    if r.d.replay_only || !r.tools.loaded do return
    for _,tool in r.tools.entries do acp_tools_close(r,tool,reason)
    acp_tools_trim(&r.tools)
}

acp_tools_destroy :: proc(r:^ACP_Runtime) {
    context.allocator=runtime.heap_allocator()
    for _,tool in r.tools.entries { acp_tool_delete(tool);free(tool) }
    delete(r.tools.entries);delete(r.tools.recent);r.tools={}
}

acp_tools_prepare :: proc(r:^ACP_Runtime,raw:string) -> bool {
    context.allocator=runtime.heap_allocator()
    if r.tools.loaded do return true
    tools:[dynamic]ACP_Tool_State
    // Register cleanup before decoding: malformed JSON can partially allocate.
    defer { for &tool in tools do acp_tool_delete(&tool);delete(tools) }
    if raw!="" && (len(raw)>ACP_TOOLS_JOURNAL_MAX || !acp_rpc_json(raw) || json.unmarshal_string(raw,&tools)!=nil) do return false
    r.tools.entries=make(map[string]^ACP_Tool_State)
    valid:=false
    defer if !valid do acp_tools_destroy(r)
    for &tool in tools {
        if tool.id=="" || len(tool.id)>1024 || len(tool.diffs)>64 || r.tools.entries[tool.id]!=nil do return false
        for text in ([]string{tool.name,tool.kind,tool.title,tool.status}) do if len(text)>4096 do return false
        for text in ([]string{tool.input,tool.output,tool.content}) do if len(text)>64*1024 do return false
        for digest in tool.diffs do if len(digest)>64 do return false
        if !tool.ended do r.tools.active+=1
        saved:=new(ACP_Tool_State);saved^=tool;tool={}
        r.tools.entries[saved.id]=saved;r.tools.bytes+=acp_tool_bytes(saved)
        if saved.ended do append(&r.tools.recent,saved.id)
        acp_tools_trim(&r.tools)
    }
    r.tools.loaded=true;r.tools.dirty=true;valid=true
    acp_tools_bound(r)
    return true
}

acp_tools_checkpoint :: proc(r:^ACP_Runtime,state:^ACP_State) -> bool {
    if !acp_tools_prepare(r,state.tool_map_json) do return false
    acp_tools_bound(r)
    if !r.tools.dirty do return true
    rows:=make([dynamic]ACP_Tool_State,allocator=context.temp_allocator)
    // Keep recent completion order on disk for eviction after recovery.
    for _,tool in r.tools.entries do if !tool.ended do append(&rows,tool^)
    for id in r.tools.recent do append(&rows,r.tools.entries[id]^)
    raw:=acp_event_json(rows)
    if len(raw)>ACP_TOOLS_JOURNAL_MAX do return false
    acp_runtime_replace(&state.tool_map_json,raw);r.tools.dirty=false
    return true
}

acp_events_ingest := bridge_ext_ingest

acp_event_string :: proc(obj: json.Object,key: string) -> string {
    value,_ := obj[key].(json.String); return string(value)
}
acp_event_object :: proc(raw: string) -> json.Object {
    value,err := json.parse(raw,allocator=context.temp_allocator)
    if err != nil do return nil
    obj,_ := value.(json.Object); return obj
}
acp_event_json :: proc(value: $T) -> string {
    raw,_ := json.marshal(value,allocator=context.temp_allocator); return string(raw)
}

// The live reducer fences old events at nanosecond precision. Scheduler timestamps
// round down to seconds and can discard a fresh call immediately after a reset.
acp_events_timestamp :: proc(now:time.Time) -> string {
    stamp,ok:=time.time_to_rfc3339(now,allocator=context.temp_allocator)
    return stamp if ok else ""
}

acp_events_emit :: proc(r: ^ACP_Runtime,event: string,payload: json.Object,tool: json.Object=nil) {
    if r.d.replay_only do return
    obj:=make(json.Object,allocator=context.temp_allocator)
    obj["schema"]=json.String(contracts.EXT_SCHEMA_V1); obj["provider"]=json.String(r.provider)
    obj["ext_version"]=json.String("acp-0.108.0"); obj["event"]=json.String(event)
    stamp:=acp_events_timestamp(time.now());if stamp=="" do return
    obj["ts"]=json.String(stamp)
    obj["session_id"]=json.String(r.session); obj["payload"]=payload
    if tool!=nil do obj["tool"]=tool
    raw:=acp_event_json(obj)
    if len(raw)>contracts.EXT_EVENT_MAX_BYTES do return
    result:=acp_events_ingest(r.rec,raw,bridge_runtime_now_ms())
    bridge_ext_ingest_result_destroy(&result)
}

acp_events_activity :: proc(r: ^ACP_Runtime,state,summary: string) {
    payload:=make(json.Object,allocator=context.temp_allocator)
    payload["state"]=json.String(state)
    if summary!="" do payload["summary"]=json.String(summary)
    acp_events_emit(r,"activity",payload)
}


acp_events_prompt_started :: proc(r: ^ACP_Runtime,input_id: string) {
    if strings.has_prefix(input_id, ACP_BOT_INPUT_PREFIX) do bridge_bot_note_dispatch(r.instance, input_id, acp_rpc_now(r.client))
    acp_events_activity(r,"active","")
    acp_chat_prompt_started(r,input_id)
}
acp_events_prompt_finished :: proc(r: ^ACP_Runtime,input_id,result,error: string) {
    reason:=acp_event_string(acp_event_object(result),"stopReason")
    if error!="" do reason=error
    if reason=="" do reason="prompt_finished_without_tool_result"
    acp_tools_finish(r,reason)
    acp_events_activity(r,"idle","")
    acp_chat_prompt_finished(r,input_id,result,error)
}

acp_events_ready :: proc(r:^ACP_Runtime) {
    acp_delivery_hello(r)
    if r.chat==nil || r.chat.d.session_announced || r.d.replay_only do return
    payload:=make(json.Object,allocator=context.temp_allocator)
    capabilities:=make(json.Array,allocator=context.temp_allocator)
    for capability in ([]string{"tool.start","tool.end","file.edit","activity"}) do append(&capabilities,json.String(capability))
    payload["capabilities"]=capabilities
    acp_events_emit(r,"hello",payload)
    session:=make(json.Object,allocator=context.temp_allocator)
    session["phase"]=json.String("start");session["source"]=json.String("resume" if r.recovering else "startup")
    acp_events_emit(r,"session",session)
    r.chat.d.session_announced=true
}

acp_events_notification :: proc(r: ^ACP_Runtime,method,params: string) {
    if method!="session/update" || r.d.replay_only do return
    obj:=acp_event_object(params)
    if acp_event_string(obj,"sessionId")!=r.session do return
    update,_:=obj["update"].(json.Object)
    switch acp_event_string(update,"sessionUpdate") {
    case "agent_thought_chunk":
        // Repeated thought chunks prove liveness, not a new turn. activity(active)
        // is a lifecycle boundary in the shared PTY tool reducer and settles any
        // orphaned calls. Only prompt_started may emit that boundary for ACP.
        bridge_runtime_note_agent_activity(r.instance,"active",bridge_ext_activity_source(r.provider))
    case "tool_call","tool_call_update": acp_events_tool(r,update)
    case "agent_message_chunk":
        content,_:=update["content"].(json.Object)
        if acp_event_string(content,"type")=="text" do acp_chat_chunk(r,acp_event_string(content,"text"))
    case "config_option_update","current_mode_update":
        acp_events_config(r,update)
    case "plan":
        raw:=acp_event_json(update)
        if len(raw)<=64*1024 do acp_runtime_replace(&r.d.plan_json,raw)
    case "user_message_chunk":
    case: // Compatible future updates are intentionally ignored.
    }
}

acp_events_config :: proc(r:^ACP_Runtime,update:json.Object) {
    config:=acp_event_object(r.d.config_json)
    if config==nil do config=make(json.Object,allocator=context.temp_allocator)
    if acp_event_string(update,"sessionUpdate")=="config_option_update" {
        options,valid:=update["configOptions"].(json.Array)
        if !valid { acp_runtime_error(r,"acp_protocol_error");return }
        config["configOptions"]=options
    } else {
        mode:=acp_event_string(update,"currentModeId")
        if mode=="" { acp_runtime_error(r,"acp_protocol_error");return }
        config["currentModeId"]=json.String(mode)
        if r.d.ready && r.descriptor.permission_category!="" && mode!=r.mode { acp_runtime_error(r,"acp_permission_mode_unsupported");return }
    }
    raw:=acp_event_json(config)
    if len(raw)>256*1024 { acp_runtime_error(r,"acp_protocol_error");return }
    acp_runtime_replace(&r.d.config_json,raw)
    // Setup responses own validation while set_config_option is in flight.
    // Once ready, unsolicited changes cannot broaden the frozen launch policy.
    if !r.d.ready do return
    for category in ([]string{r.descriptor.model_category,r.descriptor.permission_category}) {
        if category=="" do continue
        value:=r.model if category==r.descriptor.model_category else r.mode
        if value=="" || (category==r.descriptor.model_category && !acp_runtime_model_selected(r)) do continue
        id,selected:=acp_config_selection(raw,category,value,selected=true);delete(id)
        if !selected { acp_runtime_error(r,"acp_model_unavailable" if category==r.descriptor.model_category else "acp_permission_mode_unsupported");return }
    }
}

acp_events_tool :: proc(r: ^ACP_Runtime,update: json.Object) {
    id:=acp_event_string(update,"toolCallId")
    if id=="" || len(id)>1024 do return
    context.allocator=runtime.heap_allocator()
    if !acp_tools_prepare(r,r.client.state.tool_map_json) { acp_runtime_error(r,"acp_protocol_error");return }
    tool:=r.tools.entries[id]
    if tool==nil {
        if r.tools.active>=ACP_TOOLS_ACTIVE_MAX {
            acp_tools_close(r,acp_tools_largest_open(&r.tools,2),"telemetry_capacity")
            acp_tools_trim(&r.tools)
        }
        tool=new(ACP_Tool_State);tool.id=strings.clone(id)
        r.tools.entries[tool.id]=tool;r.tools.active+=1;r.tools.bytes+=acp_tool_bytes(tool)
    }
    before:=acp_tool_bytes(tool);was_ended:=tool.ended;r.tools.dirty=true
    // Completed replay receipts do not introduce a new chronological boundary.
    if !tool.ended do acp_chat_boundary(r)
    // Absent fields leave the previous partial update intact.
    for key in ([]string{"name","kind","title","status"}) {
        if value,present:=update[key];present {
            text,typed:=value.(json.String)
            if !typed || len(text)>4096 do continue
            switch key {
            case "name": acp_runtime_replace(&tool.name,string(text))
            case "kind": acp_runtime_replace(&tool.kind,string(text))
            case "title": acp_runtime_replace(&tool.title,string(text))
            case "status": acp_runtime_replace(&tool.status,string(text))
            }
        }
    }
    for key in ([]string{"rawInput","rawOutput","content"}) {
        if value,present:=update[key];present {
            raw:=acp_event_json(value)
            if len(raw)>64*1024 do continue
            switch key {
            case "rawInput": if _,object:=value.(json.Object);object do acp_runtime_replace(&tool.input,raw)
            case "rawOutput": acp_runtime_replace(&tool.output,raw)
            case "content": acp_runtime_replace(&tool.content,raw)
            }
        }
    }
    native:=make(json.Object,allocator=context.temp_allocator)
    name:=tool.name; if name=="" do name=tool.kind; if name=="" do name=tool.title
    native["name"]=json.String(name);native["use_id"]=json.String(id)
    input:=acp_event_object(tool.input)
    if input==nil do input=make(json.Object,allocator=context.temp_allocator)
    native["input"]=input
    payload:=make(json.Object,allocator=context.temp_allocator)
    terminal:=tool.status=="completed" || tool.status=="failed"
    if !tool.started && !tool.ended && (terminal || tool.status=="pending" || tool.status=="in_progress") {
        tool.started=true; acp_events_emit(r,"tool.start",payload,native)
    }
    if terminal && !tool.ended {
        tool.ended=true
        payload["outcome"]=json.String("failure" if tool.status=="failed" else "success")
        payload["status"]=json.String("error" if tool.status=="failed" else "success")
        if tool.payload_truncated do payload["telemetry_truncated"]=json.Boolean(true)
        if tool.output!="" { value,_:=json.parse(tool.output,allocator=context.temp_allocator); payload["rawOutput"]=value }
        if tool.content!="" { value,_:=json.parse(tool.content,allocator=context.temp_allocator); payload["content"]=value }
        acp_events_emit(r,"tool.end",payload,native)
    }
    if content,present:=update["content"];present {
        entries,_:=content.(json.Array)
        for entry in entries {
            diff,_:=entry.(json.Object)
            if acp_event_string(diff,"type")!="diff" do continue
            // JSON objects have no stable map order. Hash the fixed diff tuple,
            // otherwise replay of identical content can emit another edit.
            raw:=acp_event_json(struct{path,oldText,newText:string}{acp_event_string(diff,"path"),acp_event_string(diff,"oldText"),acp_event_string(diff,"newText")})
            digest:=bridge_local_hash_token(raw); defer delete(digest)
            duplicate:=false;for previous in tool.diffs do if previous==digest do duplicate=true
            if duplicate || len(tool.diffs)>=64 do continue
            append(&tool.diffs,strings.clone(digest))
            acp_events_diff(r,diff)
        }
    }
    if tool.ended {
        for field in ([]^string{&tool.name,&tool.kind,&tool.title,&tool.input,&tool.output,&tool.status,&tool.content}) {
            acp_tool_clear(field)
        }
        if !was_ended { r.tools.active-=1;append(&r.tools.recent,tool.id) }
    }
    r.tools.bytes+=acp_tool_bytes(tool)-before
    acp_tools_bound(r)
}

acp_events_diff :: proc(r:^ACP_Runtime,diff:json.Object) {
    path:=acp_event_string(diff,"path");if path=="" || len(path)>4096 do return
    old:=acp_event_string(diff,"oldText"); next:=acp_event_string(diff,"newText")
    b:=strings.builder_make(allocator=context.temp_allocator)
    fmt.sbprintf(&b,"--- %s\n+++ %s\n@@ -1,%d +1,%d @@\n",path,path,strings.count(old,"\n")+1,strings.count(next,"\n")+1)
    for text,i in ([]string{old,next}) {
        for line in strings.split(text,"\n",context.temp_allocator) {
            if len(strings.to_string(b))>contracts.EXT_DIFF_MAX_BYTES do break
            strings.write_string(&b,"-" if i==0 else "+");strings.write_string(&b,line);strings.write_byte(&b,'\n')
        }
    }
    cut,truncated:=contracts.ext_truncate_diff(strings.to_string(b));defer delete(cut)
    payload:=make(json.Object,allocator=context.temp_allocator)
    payload["path"]=json.String(path);payload["diff"]=json.String(cut);payload["diff_truncated"]=json.Boolean(truncated)
    acp_events_emit(r,"file.edit",payload)
}
