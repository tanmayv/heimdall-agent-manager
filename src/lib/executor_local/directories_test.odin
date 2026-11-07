#+feature dynamic-literals
package executor_local
import "core:testing"
import contracts "odin_test:contracts"
@(test)
executor_host_signed_directory_mapping_drain_alias_replay_and_enrollment_pins :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=fixture(t);defer destroy(f);policy(t,f)
    d:=document("directory");raw:=signed(d,"directory",&f.operator)
    testing.expect_value(t,install_directory(&f.store,raw,f.operator.public,1000,"/other").code,"invalid_resources")
    testing.expect_value(t,install_directory(&f.store,raw,f.owner1.public,1000,"/repo").code,"invalid_scope")
    testing.expect_value(t,install_directory(&f.store,raw,f.operator.public,1000,"/repo").code,"ok")
    mapping,found:=directory_mapping(&f.store,"remote_dir");testing.expect(t,found && mapping.path=="/repo" && mapping.revision==1)
    alias:=document("directory");set(alias,"directory_id","alias")
    testing.expect_value(t,install_directory(&f.store,signed(alias,"directory",&f.operator),f.operator.public,1000,"/repo").code,"ok")
    other,alias_found:=directory_mapping(&f.store,"alias");testing.expect(t,alias_found && other.key==mapping.key)
    testing.expect(t,observe_enrollment(&f.store,2,contracts.owner_payload_digest("head2")))
    testing.expect(t,!observe_enrollment(&f.store,1,contracts.owner_payload_digest("head1")))
    testing.expect(t,!observe_enrollment(&f.store,2,contracts.owner_payload_digest("fork")))
    version,hash,pinned:=enrollment_pin(&f.store);testing.expect(t,pinned && version==2 && hash==contracts.owner_payload_digest("head2"))
    p:=document("prepare");set(p,"directory_key",mapping.key)
    testing.expect_value(t,reserve(f,p,&f.owner1).code,"ok")
    second:=document("directory");set(second,"revision","2");set(second,"enabled","0")
    disable:=signed(second,"directory",&f.operator)
    testing.expect_value(t,install_directory(&f.store,disable,f.operator.public,1100,"").code,"resources_not_drained")
    testing.expect(t,expire(&f.store,3000))
    testing.expect_value(t,install_directory(&f.store,disable,f.operator.public,3000,"").code,"ok")
    _,found=directory_mapping(&f.store,"remote_dir");testing.expect(t,!found)
    historical:=install_directory(&f.store,raw,f.operator.public,3000,"");testing.expect(t,historical.code=="ok" && historical.replay)
    _,found=directory_mapping(&f.store,"remote_dir");testing.expect(t,!found,"historical mapping cannot re-enable a directory")
    set(d,"directory_path","/changed")
    testing.expect_value(t,install_directory(&f.store,signed(d,"directory",&f.operator),f.operator.public,3000,"").code,"operation_conflict")
    testing.expect(t,!exec(f.store.db,"UPDATE executor_directories SET enabled=1"))
    close(&f.store);testing.expect(t,open(&f.store,f.path,"account","executor","operator"))
    version,hash,pinned=enrollment_pin(&f.store);testing.expect(t,pinned && version==2 && hash==contracts.owner_payload_digest("head2"))
}
