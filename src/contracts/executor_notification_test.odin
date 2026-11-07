package contracts
import "core:encoding/json"
import "core:strings"
import "core:testing"

executor_notification_fixture :: proc(t:^testing.T)->json.Object {
    v,ok:=owner_content_document(#load("fixtures/executor-notification-v1.json",string))
    testing.expect(t,ok)
    f,_:=v.(json.Object)
    return f
}
@(test)
executor_notification_exact_signed_bootstrap_and_message :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=executor_notification_fixture(t)
    n,ok:=executor_parse(owner_string(f,"notification"),"notification");testing.expect(t,ok)
    b,_:=executor_parse(owner_string(f,"bootstrap"),"bootstrap")
    owner:=executor_child_key(f,"owner_key")
    message:=owner_string(f,"message")
    testing.expect(t,executor_notification_matches(n,b,message,owner,1400))
    bad,_:=f["notice_bad"].(json.Array)
    for item in bad {
        row,_:=item.(json.Object);changed,parsed:=executor_parse(owner_string(row,"raw"),"notification")
        testing.expect(t,parsed)
        testing.expectf(t,!executor_notification_matches(changed,b,message,owner,1400),"signed notification substitution %s",owner_string(row,"name"))
    }
    testing.expect(t,!executor_notification_matches(n,b,strings.concatenate({message," "},context.temp_allocator),owner,1400))
    for now in ([3]i64{1199,1800,2000}) do testing.expect(t,!executor_notification_matches(n,b,message,owner,now))
    revoked:=owner;revoked.revoked=true
    testing.expect(t,!executor_notification_matches(n,b,message,revoked,1400))
    testing.expect(t,!executor_verify("bootstrap",n,owner),"signature domains remain distinct")
}
@(test)
executor_notification_signed_result_requires_exact_input_and_progress :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=executor_notification_fixture(t)
    n,_:=executor_parse(owner_string(f,"notification"),"notification")
    result,_:=executor_parse(owner_string(f,"result"),"notification_result")
    key:=executor_child_key(f,"executor_key");message:=owner_string(f,"message")
    testing.expect(t,executor_notification_result_matches(result,n,message,key,1400))
    bad,_:=f["result_bad"].(json.Array)
    for item in bad {
        row,_:=item.(json.Object);r,parsed:=executor_parse(owner_string(row,"raw"),"notification_result")
        testing.expect(t,parsed)
        testing.expectf(t,!executor_notification_result_matches(r,n,message,key,1400),"signed result substitution %s",owner_string(row,"name"))
    }
    unsupported,_:=executor_parse(owner_string(f,"unsupported"),"notification_result")
    testing.expect(t,executor_notification_result_matches(unsupported,n,message,key,1400))
    malformed,_:=executor_parse(owner_string(f,"malformed_delivered"),"notification_result")
    testing.expect(t,!executor_notification_result_matches(malformed,n,message,key,1400))
    testing.expect(t,!executor_notification_result_matches(result,n,message,executor_child_key(f,"owner_key"),1400))
    testing.expect(t,!executor_notification_result_matches(result,n,message,key,1800))
}
@(test)
executor_notification_checkpoint_fence_is_action_scoped :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    f:=executor_notification_fixture(t)
    n,_:=executor_parse(owner_string(f,"notification"),"notification")
    q,parsed:=executor_parse(owner_string(f,"challenge"),"notification_fence_request");testing.expect(t,parsed)
    r,valid:=executor_parse(owner_string(f,"fence"),"notification_fence_reply");testing.expect(t,valid)
    owner,executor:=executor_child_key(f,"owner_key"),executor_child_key(f,"executor_key")
    testing.expect(t,executor_notification_fence_matches(r,q,n,owner,executor,1400))
    bad,_:=f["fence_bad"].(json.Array)
    for item in bad {
        row,_:=item.(json.Object);changed,ok:=executor_parse(owner_string(row,"raw"),"notification_fence_reply")
        testing.expect(t,ok)
        testing.expectf(t,!executor_notification_fence_matches(changed,q,n,owner,executor,1400),"signed fence substitution %s",owner_string(row,"name"))
    }
    testing.expect(t,!executor_verify("fence_request",q,executor),"activation nonce cannot reuse checkpoint domain")
    testing.expect(t,!executor_verify("fence_reply",r,owner))
    testing.expect(t,!executor_notification_fence_matches(r,q,n,owner,executor,1700))
}
