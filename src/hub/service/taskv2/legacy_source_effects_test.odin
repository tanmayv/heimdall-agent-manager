package taskv2

import "core:fmt"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

Legacy_Effect_Observer :: struct { t:^testing.T,fx:^Fixture,count:int }
legacy_effect_observe :: proc(ctx:rawptr,w:Wake_Command) {
    o:=(^Legacy_Effect_Observer)(ctx)
    o.count+=1
    id:=jsonx.extract_string(w.body_json,"command_id","",true,context.temp_allocator)
    testing.expect(o.t,id!="")
    testing.expect_value(o.t,scalar_text(o.fx,fmt.tprintf("SELECT input_digest FROM owner_legacy_source_effects WHERE effect_id='%s'",id)),contracts.owner_payload_digest(w.body_json))
    testing.expect_value(o.t,scalar_text(o.fx,fmt.tprintf("SELECT state FROM owner_legacy_source_effects WHERE effect_id='%s'",id)),"outstanding")
    testing.expect_value(o.t,scalar_text(o.fx,fmt.tprintf("SELECT command_id FROM owner_legacy_source_effects WHERE effect_id='%s'",id)),id)
}

@(test)
legacy_source_stop_fence_is_committed_before_exact_postcommit_dispatch :: proc(t:^testing.T) {
    fx,ok:=fixture_open(t,"source_stop")
    defer fixture_close(fx)
    if !ok do return
    chain:=seed_chain(t,fx,"source_chain",true)
    observer:=Legacy_Effect_Observer{t=t,fx=fx}
    fx.svc.wake_observer=legacy_effect_observe
    fx.svc.wake_observer_ctx=&observer
    u,opened,_:=begin_uow(&fx.svc)
    if !testing.expect(t,opened) do return
    effect_stop(&u,"executor",string(chain.chain_id),"instance")
    testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM owner_legacy_source_effects"),0)
    committed,err:=end_uow(&fx.svc,&u,true)
    testing.expect(t,committed && err.code==.None)
    testing.expect_value(t,observer.count,1)
    testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM owner_legacy_source_effects WHERE kind='stop' AND state='outstanding'"),1)
    // Dispatch acceptance is not execution absence, so freeze must still fail.
    current,_,_:=iface.taskchain_get_chain(&fx.repo,chain.chain_id)
    selection:=domain.Legacy_Migration_Selection{account_id="u1",chain_id=string(chain.chain_id),migration_id="migration",owner_bridge_id="owner",owner_key_id="key",selection_digest=strings.repeat("a",64,context.temp_allocator),expected_work_revision=current.work_revision}
    testing.expect_value(t,fx.repo.legacy_migration_select(fx.repo.ctx,selection).code,domain.Error_Code.None)
    f,found,_:=fx.repo.legacy_source_get(fx.repo.ctx,"u1",string(chain.chain_id))
    testing.expect(t,found)
    testing.expect_value(t,fx.repo.legacy_source_freeze(fx.repo.ctx,"u1",string(chain.chain_id),"migration",selection.selection_digest,strings.repeat("b",64,context.temp_allocator),1,f.generation).code,domain.Error_Code.Conflict)
}

@(test)
legacy_source_effect_storage_failure_rolls_back_mutation_and_dispatch :: proc(t:^testing.T) {
    fx,ok:=fixture_open(t,"source_rollback")
    defer fixture_close(fx)
    if !ok do return
    chain:=seed_chain(t,fx,"source_chain",true)
    observer:=Legacy_Effect_Observer{t=t,fx=fx}
    fx.svc.wake_observer=legacy_effect_observe;fx.svc.wake_observer_ctx=&observer
    if !exec_ok(t,fx,"CREATE TEMP TRIGGER fail_source_effect BEFORE INSERT ON owner_legacy_source_effects BEGIN SELECT RAISE(ABORT,'injected'); END") do return
    u,opened,_:=begin_uow(&fx.svc)
    if !testing.expect(t,opened) do return
    _=exec_ok(t,fx,"UPDATE task_chains SET title='must rollback' WHERE chain_id='source_chain'")
    effect_stop(&u,"executor",string(chain.chain_id),"instance")
    committed,err:=end_uow(&fx.svc,&u,true)
    testing.expect(t,!committed && err.code!=.None)
    testing.expect_value(t,observer.count,0)
    testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM owner_legacy_source_effects"),0)
    testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM owner_legacy_source_generations"),0)
    testing.expect(t,scalar_text(fx,"SELECT title FROM task_chains WHERE chain_id='source_chain'")!="must rollback")
}

@(test)
legacy_source_nested_effects_wait_for_outer_commit_and_rollback_fences :: proc(t:^testing.T) {
    fx,ok:=fixture_open(t,"source_nested")
    defer fixture_close(fx)
    if !ok do return
    chain:=seed_chain(t,fx,"source_chain",true)
    observer:=Legacy_Effect_Observer{t=t,fx=fx}
    fx.svc.wake_observer=legacy_effect_observe;fx.svc.wake_observer_ctx=&observer
    for commit in ([2]bool{false,true}) {
        outer,opened,_:=begin_uow(&fx.svc)
        if !testing.expect(t,opened) do return
        inner,inner_ok,_:=begin_uow(&fx.svc)
        if !testing.expect(t,inner_ok) { _,_=end_uow(&fx.svc,&outer,false);return }
        effect_stop(&inner,"executor",string(chain.chain_id),"instance")
        committed,err:=end_uow(&fx.svc,&inner,true)
        testing.expect(t,committed && err.code==.None)
        testing.expect_value(t,observer.count,0)
        testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM owner_legacy_source_effects"),1)
        _,_=end_uow(&fx.svc,&outer,commit)
        testing.expect_value(t,observer.count,int(1 if commit else 0))
        testing.expect_value(t,scalar_int(fx,"SELECT count(*) FROM owner_legacy_source_effects"),int(1 if commit else 0))
    }
}
