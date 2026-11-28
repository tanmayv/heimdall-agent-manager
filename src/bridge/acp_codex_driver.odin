package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"

// Wire shapes follow `codex app-server generate-json-schema` (0.162.0).
// The start RPC acknowledges admission; only turn/completed settles the input.
ACP_Codex_Durable :: struct {
    turn_id, start_id, steering_turn_id: string,
    completed_turns: [dynamic]string,
    message_id: string,
    message_bytes: int,
    message_done: bool,
    interrupt_deadline: i64,
    interrupt_sent: bool,
    resume_attempts: int,
    resume_retry_after: i64,
    unarchived: bool,
}

ACP_CODEX_INITIALIZE :: `{"clientInfo":{"name":"heimdall","title":"Heimdall","version":"`+contracts.APP_VERSION+`"},"capabilities":{"experimentalApi":true}}`
acp_protocol_codex_driver := ACP_Protocol_Driver{
    durable_valid = acp_codex_durable_valid,
    begin = acp_codex_begin, result = acp_codex_result,
    notification = acp_codex_notification, inbound = acp_codex_inbound,
    prompt = acp_codex_prompt, ready = acp_codex_ready,
    cancel = acp_codex_cancel, steer = acp_codex_steer,
    steering_result = acp_codex_steering_result,
    inbound_timeout = acp_permission_timeout, probe = acp_codex_probe,
    rpc = ACP_RPC_POLICY_CODEX,
    permission_request = acp_codex_permission_method, permissions_cancel = acp_permissions_cancel,
    permission_result = acp_codex_permission_result, permission_relay = acp_codex_permission_relay,
    tick = acp_codex_tick,
    can_steer = acp_codex_can_steer,
    state_key = ACP_CODEX_STATE_KEY, state_load = acp_codex_state_load,
    state_save = acp_codex_state_save, state_delete = acp_codex_state_delete,
    launch_args = acp_codex_launch_args,
    usage = acp_codex_usage,
}

// thread/tokenUsage/updated: {threadId, turnId, tokenUsage: {total, last:
// TokenUsageBreakdown, modelContextWindow: int|null}}. The context size is the
// last request's totalTokens minus its reasoningOutputTokens, the same formula
// as the PTY rollout reader (contracts.codex_context_tokens);
// output_tokens_total is the thread's cumulative output.
ACP_CODEX_USAGE_SOURCE :: "codex_token_usage"
acp_codex_usage :: proc(r: ^ACP_Runtime,method,params: string) -> (usage: contracts.Ext_Usage,ok: bool) {
    if method!="thread/tokenUsage/updated" do return
    obj := acp_event_object(params)
    if acp_event_string(obj,"threadId")!=r.session do return
    token_usage,_ := obj["tokenUsage"].(json.Object)
    last,_ := token_usage["last"].(json.Object)
    total,_ := token_usage["total"].(json.Object)
    last_total,total_ok := acp_event_integer(last,"totalTokens")
    if !total_ok || last_total<0 do return
    reasoning,_ := acp_event_integer(last,"reasoningOutputTokens")
    usage = {context_tokens=contracts.codex_context_tokens(last_total,reasoning),source=ACP_CODEX_USAGE_SOURCE}
    if output,output_ok := acp_event_integer(total,"outputTokens");output_ok && output>=0 {
        usage.output_tokens_total,usage.has_output_tokens_total = output,true
    }
    if window,window_ok := acp_event_integer(token_usage,"modelContextWindow");window_ok && window>0 {
        usage.context_window,usage.has_context_window = window,true
    }
    return usage,true
}

// Override only this child. Profile/global config files and other plugins
// remain intact; PTY launches retain their native hook setup.
acp_codex_launch_args :: proc(argv: ^[dynamic]string) {
    append(argv, "-c", "thread_unload_delay_secs=0", "-c", "features.hooks=false", "-c", "notify=[]",
        "-c", "plugins.heimdall@heimdall-codex.enabled=false")
    marketplace := bridge_codex_own_marketplace_name()
    if marketplace != "" do append(argv, "-c", strings.concatenate({"plugins.",BRIDGE_CODEX_PLUGIN_NAME,"@",marketplace,".enabled=false"},context.temp_allocator))
}

// The app-server speaks JSON-RPC without the version header, with signed
// integer request IDs, and may emit notifications whose params are not objects.
ACP_RPC_POLICY_CODEX :: ACP_RPC_Policy{
    acp_codex_role, acp_codex_timeout, acp_codex_inbound_timeout, acp_codex_cancel_timeout,
    {jsonrpc_header = false, integer_ids = true, drop_malformed_notifications = true},
}

acp_codex_durable_delete :: proc(d: ^ACP_Codex_Durable) {
    delete(d.turn_id); delete(d.start_id); delete(d.steering_turn_id); delete(d.message_id)
    for id in d.completed_turns do delete(id)
    delete(d.completed_turns); d^ = {}
}

// The runtime journal has always stored this state as the "codex" object of
// the durable runtime JSON; journals written before the state became opaque
// restore unchanged.
ACP_CODEX_STATE_KEY :: "codex"

// The driver-owned state of a durable, allocated on first use. Strings inside
// are heap-owned (acp_runtime_replace); acp_codex_state_delete frees them.
acp_codex_durable :: proc(d: ^ACP_Runtime_Durable) -> ^ACP_Codex_Durable {
    if d.driver_state == nil do d.driver_state = new(ACP_Codex_Durable, runtime.heap_allocator())
    return cast(^ACP_Codex_Durable)d.driver_state
}
acp_codex :: proc(r: ^ACP_Runtime) -> ^ACP_Codex_Durable { return acp_codex_durable(&r.d) }

acp_codex_state_load :: proc(state_json: string) -> (rawptr, bool) {
    context.allocator = runtime.heap_allocator()
    saved: ACP_Codex_Durable
    if json.unmarshal_string(state_json, &saved) != nil { acp_codex_durable_delete(&saved); return nil, false }
    return new_clone(saved), true
}
acp_codex_state_save :: proc(state: rawptr) -> (string, bool) {
    raw, err := json.marshal((cast(^ACP_Codex_Durable)state)^, allocator = context.temp_allocator)
    return string(raw), err == nil
}
acp_codex_state_delete :: proc(state: rawptr) {
    context.allocator = runtime.heap_allocator()
    if state == nil do return
    s := cast(^ACP_Codex_Durable)state
    acp_codex_durable_delete(s); free(s)
}

acp_codex_durable_valid :: proc(d: ^ACP_Runtime_Durable) -> bool {
    common := d^
    // Reuse common input/error/budget checks without widening ACP phases.
    switch d.phase {
    case "initialize", "account", "thread", "resume", "unarchive", "ready", "prompt":
    case: return false
    }
    common.phase = "ready"
    if !acp_driver_acp_durable_valid(&common) do return false
    empty: ACP_Codex_Durable
    c := cast(^ACP_Codex_Durable)d.driver_state if d.driver_state != nil else &empty
    if len(c.turn_id)>1024 || len(c.start_id)>2048 || len(c.steering_turn_id)>1024 || len(c.message_id)>1024 ||
       len(c.completed_turns)>256 || c.message_bytes<0 || c.message_bytes>contracts.ACP_ASSISTANT_MAX_BYTES ||
       c.interrupt_deadline<0 || c.resume_retry_after<0 || c.resume_attempts<0 || c.resume_attempts>3 { return false }
    for id, i in c.completed_turns {
        if id=="" || len(id)>1024 do return false
        for prior in c.completed_turns[:i] do if prior==id do return false
    }
    return true
}

acp_codex_role :: proc(method: string) -> ACP_RPC_Role {
    switch method {
    case "initialize": return .Initialize
    case "account/read": return .Config
    case "thread/start": return .New
    case "thread/resume", "thread/unarchive": return .Load
    case "turn/start": return .Prompt
    case "turn/steer": return .Steering
    }
    return .Other
}
acp_codex_timeout :: proc(method: string) -> i64 {
    return 60000 if method=="thread/start" || method=="thread/resume" else 15000
}
acp_codex_inbound_timeout :: proc(method: string) -> i64 {
    return 300000 if acp_codex_permission_method(method) else 0
}
acp_codex_cancel_timeout :: proc(method: string) -> i64 { return 0 }

acp_codex_begin :: proc(r: ^ACP_Runtime) -> bool {
    if r.recovering && acp_codex(r).turn_id!="" do acp_codex_remember_turn(r,acp_codex(r).turn_id)
    acp_runtime_replace(&r.d.phase, "initialize")
    acp_runtime_replace(&acp_codex(r).turn_id, "")
    acp_runtime_replace(&acp_codex(r).start_id, "")
    acp_runtime_replace(&acp_codex(r).steering_turn_id, "")
    acp_codex(r).interrupt_deadline = 0
    acp_codex(r).interrupt_sent = false; acp_codex(r).resume_retry_after = 0
    return acp_runtime_request(r, "initialize", ACP_CODEX_INITIALIZE)
}

acp_codex_policy :: proc(r: ^ACP_Runtime, target: ^json.Object, thread_policy: bool) -> bool {
    params := target^
    defer target^ = params
    if r.mode!="ask" && r.mode!="yolo" { acp_runtime_error(r,"acp_permission_mode_unsupported"); return false }
    approval: json.Value = json.String("on-request")
    if r.mode=="yolo" {
        approval = acp_event_object(`{"granular":{"mcp_elicitations":true,"rules":false,"sandbox_approval":false,"request_permissions":false,"skill_approval":false}}`)
    }
    params["approvalPolicy"] = approval
    // Do not inherit a profile's automatic reviewer for bridge-owned approvals.
    params["approvalsReviewer"] = json.String("user")
    params["cwd"] = json.String(r.run_dir)
    if acp_runtime_model_selected(r) do params["model"] = json.String(r.model)
    if thread_policy {
        params["sandbox"] = json.String("workspace-write" if r.mode=="ask" else "danger-full-access")
    } else {
        params["sandboxPolicy"] = acp_event_object(`{"type":"workspaceWrite"}` if r.mode=="ask" else `{"type":"dangerFullAccess"}`)
        // No separate effort field is present in the launch contract. Null
        // preserves the selected profile's configured model reasoning effort.
        params["effort"] = json.Null(nil)
    }
    return true
}

acp_codex_thread :: proc(r: ^ACP_Runtime) -> bool {
    params := make(json.Object, allocator=context.temp_allocator)
    if !acp_codex_policy(r,&params,true) do return false
    path := strings.concatenate({r.run_dir,"/",r.binding.bootstrap_filename},context.temp_allocator)
    bootstrap, err := os.read_entire_file(path,context.temp_allocator)
    if err!=nil || len(bootstrap)==0 || len(bootstrap)>ACP_RPC_MAX_LINE/2 {
        acp_runtime_error(r,"acp_bootstrap_unsupported"); return false
    }
    params["developerInstructions"] = json.String(string(bootstrap))
    method := "thread/start"
    if r.recovering {
        if r.session=="" { acp_runtime_error(r,"acp_pipe_lost"); return false }
        method = "thread/resume"; params["threadId"] = json.String(r.session)
        r.d.replay_only = true
    }
    acp_runtime_replace(&r.d.phase,"resume" if r.recovering else "thread")
    return acp_runtime_request(r,method,acp_event_json(params))
}

acp_codex_ready :: proc(r: ^ACP_Runtime) {
    // Developer instructions already carry the bootstrap text.
    r.d.replay_only = false; r.d.steering_supported = true
    acp_runtime_session_ready(r,starter_links_bootstrap=false)
}

acp_codex_prompt :: proc(r: ^ACP_Runtime,input: Bridge_Inbox_Input,bootstrap: bool) {
    if r.d.phase=="prompt" { acp_runtime_error(r,"acp_protocol_error"); return }
    params := make(json.Object,allocator=context.temp_allocator)
    if !acp_codex_policy(r,&params,false) do return
    params["threadId"] = json.String(r.session)
    params["input"] = acp_event_object(acp_event_json(struct{input:[1]struct{type,text:string}}{input={{"text",input.text}}}))["input"]
    r.d.cancelling=false; acp_codex(r).interrupt_deadline=0; acp_codex(r).interrupt_sent=false
    acp_runtime_replace(&acp_codex(r).turn_id,"")
    acp_runtime_replace(&acp_codex(r).message_id,""); acp_codex(r).message_bytes=0; acp_codex(r).message_done=false
    acp_runtime_replace(&r.d.phase,"prompt"); acp_runtime_replace(&r.d.current_input,input.id)
    // Predict the dispatcher-owned counter so the start identity is in the
    // same checkpoint as the outgoing RPC, including before a lost receipt.
    acp_runtime_replace(&acp_codex(r).start_id,acp_rpc_internal_id(r.epoch,r.client.state.next_rpc_id))
    if acp_runtime_events.prompt_started!=nil do acp_runtime_events.prompt_started(r,input.id)
    if acp_runtime_request(r,"turn/start",acp_event_json(params)) do bridge_runtime_note_agent_activity(r.instance,"active","acp")
}

acp_codex_turn_known :: proc(r: ^ACP_Runtime,id: string) -> bool {
    for prior in acp_codex(r).completed_turns do if prior==id do return true
    return false
}
acp_codex_remember_turn :: proc(r: ^ACP_Runtime,id: string) {
    if id=="" || acp_codex_turn_known(r,id) do return
    append(&acp_codex(r).completed_turns,strings.clone(id))
    if len(acp_codex(r).completed_turns)>256 { delete(acp_codex(r).completed_turns[0]); ordered_remove(&acp_codex(r).completed_turns,0) }
}
acp_codex_bind_turn :: proc(r: ^ACP_Runtime,id: string) -> bool {
    if id=="" || len(id)>1024 || acp_codex_turn_known(r,id) || (acp_codex(r).turn_id!="" && acp_codex(r).turn_id!=id) {
        acp_runtime_error(r,"acp_protocol_error"); return false
    }
    acp_runtime_replace(&acp_codex(r).turn_id,id)
    return true
}

acp_codex_result :: proc(data: rawptr,result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error!="" do return
    // A completed notification may precede its admission response. Never bind
    // that late response to a newer queued input.
    if result.method=="turn/start" && string(result.id)!=acp_codex(r).start_id do return
    if !result.ok {
        if result.error.message=="acp_pipe_lost" || result.error.message=="acp_pipe_gap" do return
        if result.method=="thread/resume" && !strings.has_prefix(result.error.message,"acp_") {
            message := strings.to_lower(result.error.message,context.temp_allocator)
            if strings.contains(message,"archived") && !acp_codex(r).unarchived {
                acp_codex(r).unarchived=true; acp_runtime_replace(&r.d.phase,"unarchive")
                acp_runtime_request(r,"thread/unarchive",acp_event_json(struct{threadId:string}{r.session})); return
            }
            if strings.contains(message,"closing") && acp_codex(r).resume_attempts<3 {
                acp_codex(r).resume_attempts+=1
                acp_codex(r).resume_retry_after=acp_rpc_now(r.client)+250*i64(acp_codex(r).resume_attempts)
                return
            }
            // Unknown/not-found/archived after one unarchive never creates a
            // replacement conversation or replays the interrupted input.
            acp_runtime_error(r,"acp_pipe_lost"); return
        }
        reason := "acp_rpc_failed"
        switch result.error.message {
        case "acp_rpc_timeout","acp_pipe_write_failed","acp_adapter_exited","acp_protocol_error","acp_state_write_failed": reason=result.error.message
        }
        acp_runtime_error(r,reason); return
    }
    value,parse_err := json.parse(result.result_json,allocator=context.temp_allocator)
    obj,object_ok := value.(json.Object)
    if parse_err!=nil || !object_ok { acp_runtime_error(r,"acp_protocol_error"); return }
    switch result.method {
    case "initialize":
        if r.d.phase!="initialize" do return
        if acp_event_string(obj,"userAgent")=="" { acp_runtime_error(r,"acp_protocol_error"); return }
        r.initialized=true; r.load_session=true
        if !acp_rpc_notify(r.client,"initialized","{}") { acp_runtime_error(r,"acp_pipe_write_failed"); return }
        acp_runtime_replace(&r.d.phase,"account")
        acp_runtime_request(r,"account/read",`{"refreshToken":false}`)
    case "account/read":
        required, typed := obj["requiresOpenaiAuth"].(json.Boolean)
        account, present := obj["account"]
        _, object := account.(json.Object)
        _, null := account.(json.Null)
        if !typed || (present && !object && !null) { acp_runtime_error(r,"acp_protocol_error"); return }
        if bool(required) && !object { acp_runtime_error(r,"acp_auth_required",auth=true); return }
        acp_codex_thread(r)
    case "thread/start","thread/resume":
        thread_obj,_ := obj["thread"].(json.Object)
        id := acp_event_string(thread_obj,"id")
        if id=="" || len(id)>1024 || (r.recovering && id!=r.session) { acp_runtime_error(r,"acp_protocol_error"); return }
        acp_runtime_replace(&r.session,id)
        acp_codex(r).resume_attempts=0
        acp_codex_ready(r)
    case "thread/unarchive": acp_codex_thread(r)
    case "turn/start":
        if r.d.phase!="prompt" do return
        turn,_ := obj["turn"].(json.Object)
        if !acp_codex_bind_turn(r,acp_event_string(turn,"id")) do return
        // An interrupt can arrive before start yields the native turn ID.
        if r.d.cancelling do acp_codex_cancel(r)
        acp_runtime_drain(r)
    case "turn/interrupt": // Ack only; turn/completed owns completion.
    }
}

acp_codex_finish :: proc(r: ^ACP_Runtime,turn: json.Object) {
    status := acp_event_string(turn,"status")
    reason,error := "end_turn",""
    switch status {
    case "completed":
    case "interrupted": reason="cancelled"
    case "failed": reason="acp_rpc_failed"; error=reason
    case: return // Undecodable notifications are dropped.
    }
    acp_permissions_cancel(r)
    if acp_runtime_events.prompt_finished!=nil do acp_runtime_events.prompt_finished(r,r.d.current_input,acp_event_json(struct{stopReason:string}{reason}),error)
    bridge_inbox_remember(r.inbox, r.d.current_input)
    acp_codex_remember_turn(r,acp_codex(r).turn_id)
    acp_runtime_replace(&r.d.current_input,""); acp_runtime_replace(&acp_codex(r).start_id,"")
    acp_runtime_replace(&acp_codex(r).turn_id,""); acp_runtime_replace(&r.d.phase,"ready")
    r.d.cancelling=false; acp_codex(r).interrupt_deadline=0; acp_codex(r).interrupt_sent=false
    bridge_runtime_note_agent_activity(r.instance,"idle","acp")
    acp_runtime_drain(r)
}

acp_codex_notification :: proc(r: ^ACP_Runtime,method,params: string) {
    obj := acp_event_object(params)
    if obj==nil || r.d.replay_only || acp_event_string(obj,"threadId")!=r.session || r.d.phase!="prompt" do return
    if method=="turn/started" || method=="turn/completed" {
        turn,_ := obj["turn"].(json.Object)
        id := acp_event_string(turn,"id")
        if id=="" do return
        if method=="turn/completed" && acp_codex_turn_known(r,id) do return
        if !acp_codex_bind_turn(r,id) do return
        if method=="turn/completed" { acp_codex_finish(r,turn) }
        else {
            if r.d.cancelling do acp_codex_cancel(r)
            acp_runtime_drain(r)
        }
        return
    }
    id := acp_event_string(obj,"turnId")
    if id=="" || id!=acp_codex(r).turn_id do return
    switch method {
    case "item/agentMessage/delta":
        item := acp_event_string(obj,"itemId"); delta := acp_event_string(obj,"delta")
        if item=="" || len(item)>1024 || delta=="" do return
        if acp_codex(r).message_id!=item {
            acp_runtime_replace(&acp_codex(r).message_id,item); acp_codex(r).message_bytes=0; acp_codex(r).message_done=false
        }
        if acp_codex(r).message_done do return
        acp_codex(r).message_bytes=min(acp_codex(r).message_bytes+len(delta),contracts.ACP_ASSISTANT_MAX_BYTES)
        acp_chat_chunk(r,delta)
    case "item/started","item/completed":
        item,_ := obj["item"].(json.Object)
        acp_codex_item(r,item,method=="item/completed")
    case "item/commandExecution/outputDelta":
        // Stream output into the existing bounded tool cache. The completed
        // item supplies the authoritative full output, including on replay.
        item := acp_event_string(obj,"itemId"); delta := acp_event_string(obj,"delta")
        if item=="" || delta=="" do return
        tool := r.tools.entries[item]
        if tool==nil || tool.ended do return
        previous: json.Value
        if tool.output!="" { previous,_=json.parse(tool.output,allocator=context.temp_allocator) }
        text,_ := previous.(json.String)
        output := strings.concatenate({string(text),delta},context.temp_allocator)
        if len(output)>48*1024 {
            cut:=48*1024
            for cut>0 && (output[cut]&0xc0)==0x80 do cut-=1
            output=output[:cut]
        }
        update := acp_event_object(acp_event_json(struct{toolCallId,rawOutput:string}{item,output}))
        acp_events_tool(r,update)
    case "item/reasoning/summaryTextDelta","item/reasoning/textDelta":
        bridge_runtime_note_agent_activity(r.instance,"active","acp")
    case "turn/plan/updated":
        if len(params)<=64*1024 do acp_runtime_replace(&r.d.plan_json,params)
    case "error":
        retry,typed := obj["willRetry"].(json.Boolean)
        if typed && bool(retry) do bridge_runtime_note_agent_activity(r.instance,"active","acp")
        // Even terminal error detail is followed by turn/completed. Do not
        // finalize early or expose unsanitized provider error strings.
    }
}

acp_codex_item :: proc(r: ^ACP_Runtime,item: json.Object,completed: bool) {
    id,kind := acp_event_string(item,"id"),acp_event_string(item,"type")
    if id=="" || len(id)>1024 do return
    if kind=="agentMessage" {
        if !completed do return
        if acp_codex(r).message_id!=id {
            acp_runtime_replace(&acp_codex(r).message_id,id); acp_codex(r).message_bytes=0; acp_codex(r).message_done=false
        }
        if !acp_codex(r).message_done {
            text := acp_event_string(item,"text")
            if len(text)>acp_codex(r).message_bytes do acp_chat_chunk(r,text[acp_codex(r).message_bytes:])
            acp_codex(r).message_done=true
        }
        return
    }
    if kind=="reasoning" { bridge_runtime_note_agent_activity(r.instance,"active","acp"); return }
    if kind!="commandExecution" && kind!="fileChange" && kind!="mcpToolCall" do return
    update := make(json.Object,allocator=context.temp_allocator)
    update["toolCallId"]=json.String(id); update["name"]=json.String(kind)
    update["kind"]=json.String("execute" if kind=="commandExecution" else "edit")
    update["title"]=json.String(acp_event_string(item,"command") if kind=="commandExecution" else kind)
    status := acp_event_string(item,"status")
    failed := status=="failed" || status=="declined"
    update["status"]=json.String(("failed" if failed else "completed") if completed else "in_progress")
    update["rawInput"]=item
    if output,present:=item["aggregatedOutput"];present do update["rawOutput"]=output
    if kind=="fileChange" && completed && !failed {
        changes,_ := item["changes"].(json.Array)
        for change in changes {
            obj,_ := change.(json.Object)
            path,diff := acp_event_string(obj,"path"),acp_event_string(obj,"diff")
            if path=="" || len(path)>4096 do continue
            // Codex supplies a unified diff rather than ACP old/new text.
            // Reuse tool receipts to suppress repeated terminal items.
            tool := r.tools.entries[id]
            if tool!=nil && tool.ended do continue
            payload := make(json.Object,allocator=context.temp_allocator)
            cut,truncated := contracts.ext_truncate_diff(diff)
            defer if truncated do delete(cut)
            payload["path"]=json.String(path); payload["diff"]=json.String(cut); payload["diff_truncated"]=json.Boolean(truncated)
            acp_events_emit(r,"file.edit",payload)
        }
    }
    acp_events_tool(r,update)
}

acp_codex_cancel :: proc(r: ^ACP_Runtime) -> bool {
    if r.d.phase!="prompt" do return true
    r.d.cancelling=true
    if acp_codex(r).interrupt_deadline==0 do acp_codex(r).interrupt_deadline=acp_rpc_now(r.client)+10000
    // The start response/notification will deliver it once the ID is known.
    if acp_codex(r).turn_id=="" do return acp_rpc_checkpoint(r.client)
    if acp_codex(r).interrupt_sent do return acp_rpc_checkpoint(r.client)
    acp_codex(r).interrupt_sent=true
    // Stop marks the owner stopped before calling the driver. This control
    // request must still reach the live child before its normal Close path.
    id,sent := acp_rpc_request(r.client,"turn/interrupt",acp_event_json(struct{threadId,turnId:string}{r.session,acp_codex(r).turn_id}),0,{acp_runtime_result,r})
    delete(string(id),runtime.heap_allocator()); return sent
}
acp_codex_tick :: proc(r: ^ACP_Runtime) {
    if r.d.error!="" do return
    if acp_codex(r).resume_retry_after!=0 && acp_rpc_now(r.client)>=acp_codex(r).resume_retry_after {
        acp_codex(r).resume_retry_after=0
        acp_codex_thread(r)
    }
    if acp_codex(r).interrupt_deadline!=0 && acp_rpc_now(r.client)>=acp_codex(r).interrupt_deadline && r.d.phase=="prompt" {
        acp_runtime_error(r,"acp_rpc_timeout")
    }
}
acp_codex_steer :: proc(r: ^ACP_Runtime) -> bool {
    acp_runtime_replace(&acp_codex(r).steering_turn_id,acp_codex(r).turn_id)
    raw := acp_event_json(struct{threadId,expectedTurnId:string,input:[1]struct{type,text:string}}{
        r.session,acp_codex(r).turn_id,{{"text",r.d.steering_input.text}}})
    id,sent := acp_rpc_request(r.client,"turn/steer",raw,0,{acp_inbox_steering_result,r})
    delete(string(id),runtime.heap_allocator()); return sent
}
// Steering targets the native turn id; before turn/start or turn/started
// yields it, an input waits for the id rather than cancelling the turn.
acp_codex_can_steer :: proc(r: ^ACP_Runtime) -> ACP_Steer_Readiness {
    if r.d.cancelling do return .Never
    state := cast(^ACP_Codex_Durable)r.d.driver_state
    return .Now if state!=nil && state.turn_id!="" else .Later
}
acp_codex_steering_result :: proc(data: rawptr,result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    r := cast(^ACP_Runtime)data
    if !acp_runtime_current(r) || r.d.error!="" do return
    if !result.ok && (result.error.message=="acp_pipe_lost" || result.error.message=="acp_pipe_gap") do return
    input := r.d.steering_input
    if !r.d.steering_pending do return
    obj := acp_event_object(result.result_json)
    injected := result.ok && acp_event_string(obj,"turnId")!=""
    if injected && acp_event_string(obj,"turnId")!=acp_codex(r).steering_turn_id {
        acp_runtime_error(r,"acp_protocol_error"); return
    }
    if result.ok && !injected { acp_runtime_error(r,"acp_protocol_error"); return }
    r.d.steering_input={}; r.d.steering_pending=false
    acp_runtime_replace(&acp_codex(r).steering_turn_id,"")
    if injected {
        if r.d.phase=="prompt" do acp_chat_boundary(r)
        acp_delivery_steer_injected(r,input)
        bridge_inbox_remember(r.inbox, input.id); bridge_inbox_input_delete(input)
    } else {
        // A rejected steer was not injected. Retain it at the FRONT for the
        // next turn (FIFO) and never steer it again.
        if result.error.code==-32601 do r.d.steering_supported=false
        acp_delivery_steer_rejected(r,input)
    }
    if !acp_rpc_checkpoint(r.client) { acp_runtime_error(r,"acp_state_write_failed"); return }
    acp_runtime_drain(r)
}

acp_codex_permission_method :: proc(method: string) -> bool {
    switch method {
    case "item/commandExecution/requestApproval","item/fileChange/requestApproval","item/permissions/requestApproval","execCommandApproval","applyPatchApproval": return true
    }
    return false
}
acp_codex_permission_result :: proc(method,params,decision: string) -> string {
    if method=="item/permissions/requestApproval" {
        if decision!="allow" do return `{"permissions":{},"scope":"turn"}`
        obj := acp_event_object(params)
        permissions,valid := obj["permissions"].(json.Object)
        if !valid do return `{"permissions":{},"scope":"turn"}`
        return acp_event_json(struct{permissions:json.Object,scope:string}{permissions,"turn"})
    }
    if method=="execCommandApproval" || method=="applyPatchApproval" {
        if decision=="allow" do return `{"decision":"approved"}`
        if decision=="deny" do return `{"decision":{"denied":{"rejection":"Denied by the user"}}}`
        return `{"decision":"abort"}`
    }
    choice := "accept" if decision=="allow" else ("decline" if decision=="deny" else "cancel")
    return acp_event_json(struct{decision:string}{choice})
}
acp_codex_permission_relay :: proc(method,params,blocker,provider: string,timeout_ms: int) -> Bridge_Ext_Permission_Request {
    obj := acp_event_object(params)
    id := acp_event_string(obj,"itemId"); if id=="" do id=acp_event_string(obj,"callId")
    name := "Command" if method=="execCommandApproval" || method=="item/commandExecution/requestApproval" else "File change"
    if method=="item/permissions/requestApproval" do name="Permissions"
    return {provider=provider,tool_name=name,tool_use_id=id,input=params,suggestions="[]",timeout_ms=timeout_ms,blocker_id=blocker,explicit_decision_only=true}
}
acp_codex_inbound :: proc(r: ^ACP_Runtime,id,method,params: string) -> bool {
    if !acp_codex_permission_method(method) do return false
    obj := acp_event_object(params)
    thread_id := acp_event_string(obj,"threadId")
    if thread_id=="" do thread_id=acp_event_string(obj,"conversationId")
    turn := acp_event_string(obj,"turnId")
    if thread_id!=r.session || r.session=="" || r.d.phase!="prompt" ||
       (turn!="" && turn!=acp_codex(r).turn_id) {
        acp_rpc_reply(r.client,id,acp_codex_permission_result(method,params,"none")); return true
    }
    acp_permission_start(r,id,params); return true
}

acp_codex_probe_result :: proc(data: rawptr,result: ACP_RPC_Result) {
    defer acp_rpc_result_delete(result)
    p := cast(^ACP_Adapter_Probe)data
    obj := acp_event_object(result.result_json)
    sync.mutex_lock(&p.mu)
    p.ok=result.ok && acp_event_string(obj,"userAgent")!=""; p.done=true
    sync.cond_broadcast(&p.cond); sync.mutex_unlock(&p.mu)
}
acp_codex_probe :: proc(c: ^ACP_RPC_Client,p: ^ACP_Adapter_Probe) -> bool {
    id,sent := acp_rpc_request(c,"initialize",ACP_CODEX_INITIALIZE,15000,{acp_codex_probe_result,p})
    delete(string(id),runtime.heap_allocator()); return sent
}
