package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import compact "odin_test:lib/context_compaction"

// Requirements are exact authoritative text. Only the derived chain context is
// bounded. This dedicated owner-local route does not grant legacy Hub authority.
bridge_owner_render_context :: proc(command:json.Object,body:string) -> string {
    value,parse_error:=json.parse_string(body,.JSON,true,context.temp_allocator)
    result,is_object:=value.(json.Object)
    if parse_error!=.None || !is_object do return ""
    get:=contracts.owner_string
    if get(result,"requirements_revision")=="" || get(result,"brief")=="" || get(result,"context_provenance")=="" do return ""
    summary:=compact.project("# Chain context", "Original sources: signed context.read cursor pages on the owner Bridge.",strings.split_lines(get(result,"chain_summary"),context.temp_allocator))
    return fmt.tprintf("# Owner-local task %s\n\n- Chain: %s\n- Lease: %s\n- Instance: %s\n- Requirements revision: %s\n- Acknowledged: %s\n\n## Current requirements (complete)\n```json\n%s\n```\n\n## Chain summary\n%s\n\n## Context provenance\n```json\n%s\n```\n\nUse the owner-local lease/lifecycle commands for this chain. Presenting requirements does not acknowledge them; explicitly call requirements.ack for this lease and revision. Historical receipt replays do not overwrite newer TASK.md files.\n",
        get(command,"task_id"),get(command,"chain_id"),get(command,"lease_id"),get(command,"instance_id"),get(result,"requirements_revision"),get(result,"acknowledged"),get(result,"brief"),summary,get(result,"context_provenance"))
}

bridge_owner_materialize_context :: proc(run_dir:string,command:json.Object,body:string) -> bool {
    clean:=strings.trim_right(strings.trim_space(run_dir),"/")
    if clean=="" do return false
    text:=bridge_owner_render_context(command,body)
    if text=="" || len(text)>BRIDGE_TASK_MD_MAX_BYTES do return false
    path:=strings.concatenate({clean,"/TASK.md"},context.temp_allocator)
    sync.mutex_guard(&bridge_taskv2_task_md_mutex)
    return bridge_retry_atomic_write(path,transmute([]byte)text)
}
