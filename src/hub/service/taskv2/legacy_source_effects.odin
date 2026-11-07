package taskv2

import "core:fmt"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"

Prepared_Legacy_Wake :: struct {
    bridge_id,chain_id,command_id,body_json,key:string,
    source_generation:i64,
}

// Persist exact dispatch hashes inside the mutation transaction, including
// nested SAVEPOINT effects. Only after commit may the prepared bytes be sent.
// There is deliberately no 'sent means drained' shortcut. Lost callbacks and
// process crashes retain outstanding fences for explicit executor quiescence.
prepare_legacy_source_effects :: proc(svc:^Service,e:^Effects) -> domain.Domain_Error {
    if svc.repo==nil || svc.repo.legacy_effect_prepare==nil do return {}
    keys:=make(map[string]bool,context.temp_allocator)
    for key in e.runs do keys[key]=true
    for key in e.stops do keys[key]=true
    for key in keys {
        bridge,chain:=split_wake_key(key)
        runs,stops:=e.runs[key],e.stops[key]
        if bridge=="" || (len(runs)==0 && len(stops)==0) do continue
        source,found,err:=iface.taskchain_get_chain(svc.repo,domain.Task_Chain_ID(chain))
        if err.code!=.None do return err
        if !found do return domain.domain_error(.Conflict,"legacy effect source chain unavailable")
        id:=platform.generate_id(svc.ids,"cmd_")
        body:=agent.wake_agent_command_json(id,chain,runs[:],stops[:])
        defer delete(body)
        kind:="wake"
        if len(runs)==0 do kind="stop"
        generation,perr:=svc.repo.legacy_effect_prepare(svc.repo.ctx,domain.Legacy_Source_Effect{
          account_id=string(source.owner_user_id),chain_id=chain,effect_id=id,command_id=id,bridge_id=bridge,kind=kind,input_digest=contracts.owner_payload_digest(body)})
        if perr.code!=.None do return perr
        append(&e.source_wakes,Prepared_Legacy_Wake{strings.clone(bridge),strings.clone(chain),strings.clone(id),strings.clone(body),strings.clone(key),generation})
    }
    for &m in e.merges {
        task,found,err:=iface.taskchain_get_task(svc.repo,domain.Task_ID(m.task_id))
        if err.code!=.None do return err
        if !found do return domain.domain_error(.Conflict,"legacy merge source task unavailable")
        command_id:=fmt.tprintf("cmd_merge_%s_%d",task.task_id,task.attempt_no)
        body:=merge_command_json(command_id,m)
        // Each dispatch attempt gets its own source fence, while the existing
        // Bridge merge command identity remains stable/idempotent.
        effect_id:=platform.generate_id(svc.ids,"effect_merge_")
        generation,perr:=svc.repo.legacy_effect_prepare(svc.repo.ctx,domain.Legacy_Source_Effect{
          account_id=string(task.owner_user_id),chain_id=string(task.chain_id),effect_id=effect_id,command_id=command_id,bridge_id=m.bridge_id,kind="merge",input_digest=contracts.owner_payload_digest(body)})
        if perr.code!=.None do return perr
        m.source_command_id=strings.clone(command_id)
        m.source_body=strings.clone(body)
        m.source_effect_id=strings.clone(effect_id)
        m.source_generation=generation
    }
    return {}
}
