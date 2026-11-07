package contracts

import "core:encoding/json"
import "core:testing"
import "core:strings"

executor_child_fixture :: proc(t:^testing.T)->json.Object {
    v,ok:=owner_content_document(#load("fixtures/executor-child-v1.json",string))
    testing.expect(t,ok)
    root,_:=v.(json.Object)
    return root
}
executor_child_key :: proc(root:json.Object,name:string)->Owner_Verified_Key {
    o,_:=root[name].(json.Object)
    return {owner_string(o,"account_id"),owner_string(o,"principal_id"),owner_string(o,"key_id"),
        owner_string(o,"public_key"),"bridge",true,false}
}
@(test)
executor_bootstrap_exact_signed_binding :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=executor_child_fixture(t)
    b,_:=executor_parse(owner_string(f,"bootstrap"),"bootstrap")
    p,_:=executor_parse(owner_string(f,"prepare"),"prepare")
    a,_:=executor_parse(owner_string(f,"action"),"action")
    key:=executor_child_key(f,"owner_key")
    config,body,launch:=owner_string(f,"configuration"),owner_string(f,"body"),owner_string(b,"launch_key")
    testing.expect(t,executor_bootstrap_matches(b,p,a,config,body,launch,key,1300))
    bad,_:=f["bootstrap_bad"].(json.Array)
    for item in bad {
        row,_:=item.(json.Object)
        changed,valid:=executor_parse(owner_string(row,"raw"),"bootstrap")
        testing.expect(t,valid)
        testing.expectf(t,!executor_bootstrap_matches(changed,p,a,config,body,launch,key,1300),"reject signed change %s",owner_string(row,"name"))
    }
    testing.expect(t,!executor_bootstrap_matches(b,p,a,config,strings.concatenate({body," "},context.temp_allocator),launch,key,1300))
    testing.expect(t,!executor_bootstrap_matches(b,p,a,strings.concatenate({config," "},context.temp_allocator),body,launch,key,1300))
    for now in ([3]i64{1099,1900,2000}) do testing.expect(t,!executor_bootstrap_matches(b,p,a,config,body,launch,key,now))
    revoked:=key;revoked.revoked=true
    testing.expect(t,!executor_bootstrap_matches(b,p,a,config,body,launch,revoked,1300))
    testing.expect(t,!executor_verify("bootstrap",b,executor_child_key(f,"executor_key")))
}
@(test)
executor_child_request_exact_signed_binding :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=executor_child_fixture(t)
    b,_:=executor_parse(owner_string(f,"bootstrap"),"bootstrap")
    r,_:=executor_parse(owner_string(f,"child"),"child_request")
    owner,executor:=executor_child_key(f,"owner_key"),executor_child_key(f,"executor_key")
    input:=owner_string(f,"input")
    testing.expect(t,executor_child_request_matches(r,b,input,executor,owner,1300))
    bad,_:=f["child_bad"].(json.Array)
    for item in bad {
        row,_:=item.(json.Object)
        changed,valid:=executor_parse(owner_string(row,"raw"),"child_request")
        testing.expect(t,valid)
        testing.expectf(t,!executor_child_request_matches(changed,b,input,executor,owner,1300),"reject signed change %s",owner_string(row,"name"))
    }
    testing.expect(t,!executor_child_request_matches(r,b,strings.concatenate({input," "},context.temp_allocator),executor,owner,1300))
    testing.expect(t,!executor_child_request_matches(r,b,"{}",executor,owner,1300))
    for now in ([3]i64{1199,1800,2000}) do testing.expect(t,!executor_child_request_matches(r,b,input,executor,owner,now))
    revoked:=executor;revoked.revoked=true
    testing.expect(t,!executor_child_request_matches(r,b,input,revoked,owner,1300))
    testing.expect(t,!executor_verify("child_request",r,owner))
}

@(test)
executor_bootstrap_content_rejects_authority_and_path_injection :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=executor_child_fixture(t)
    _,exchange_valid:=executor_parse(owner_string(f,"activation_exchange"),"activation_bootstrap_exchange")
    testing.expect(t,exchange_valid)
    _,valid:=executor_parse(owner_string(f,"body"),"bootstrap_content")
    testing.expect(t,valid)
    bad,_:=f["content_bad"].(json.Array)
    for item in bad {
        raw,_:=item.(json.String)
        _,accepted:=executor_parse(string(raw),"bootstrap_content")
        testing.expect(t,!accepted)
    }
}
