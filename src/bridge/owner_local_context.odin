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
    workdir:=""
    if work:=get(command,"workdir");work!="" && get(command,"branch")=="" {
        workdir=fmt.tprintf("- Workdir: `%s` (this chain has no project directory: your run directory; nothing is merged back). Do the work there.\n",work)
    } else if work!="" {
        workdir=fmt.tprintf("- Workdir: `%s` on branch `%s`. `cd` there and do all work and commits in it; it is merged into the target branch after review.\n",work,get(command,"branch"))
    } else if problem:=get(command,"workdir_error");problem!="" {
        workdir=fmt.tprintf("- Workdir: unavailable (%s). Your lease is held; run `ham-ctl lease next` again to retry before working.\n",problem)
    }
    summary:=compact.project("# Chain context", "Original sources: signed context.read cursor pages on the owner Bridge.",strings.split_lines(get(result,"chain_summary"),context.temp_allocator))
    return fmt.tprintf("# Owner-local task %s\n\n- Chain: %s\n- Lease: %s\n- Instance: %s\n- Requirements revision: %s\n- Acknowledged: %s\n%s\n## Current requirements (complete)\n```json\n%s\n```\n\n## Chain summary\n%s\n\n## Context provenance\n```json\n%s\n```\n\nThis chain is held by its owner Bridge; the ordinary verbs work on it. Presenting requirements does not acknowledge them: after reading this file run `ham-ctl lease heartbeat --lease %s --acknowledge-requirements-revision %s`, then commit in the Workdir and `ham-ctl lease submit --summary <checks and outcomes>`. Historical receipt replays do not overwrite newer TASK.md files.\n",
        get(command,"task_id"),get(command,"chain_id"),get(command,"lease_id"),get(command,"instance_id"),get(result,"requirements_revision"),get(result,"acknowledged"),workdir,get(result,"brief"),summary,get(result,"context_provenance"),get(command,"lease_id"),get(result,"requirements_revision"))
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
