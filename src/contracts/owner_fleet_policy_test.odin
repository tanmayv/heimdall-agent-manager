package contracts

import "core:encoding/json"
import "core:testing"

OWNER_FLEET_POLICY_FIXTURE :: #load("fixtures/owner-fleet-policy.json")

@(test)
owner_fleet_policy_native_shape_is_strict_and_preserves_exact_integers :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    raw:=string(OWNER_FLEET_POLICY_FIXTURE)
    policy,ok:=owner_fleet_policy_parse(raw)
    if !testing.expect(t,ok) do return
    testing.expect_value(t,policy.capacity,i64(9007199254740993))
    testing.expect_value(t,policy.created_at,"2020-01-02T03:04:05.123456+05:30")
    testing.expect_value(t,policy.model,"模型🚀")
    value,_:=owner_content_document(raw);row,_:=value.(json.Object)
    for bad in ([5]json.Value{json.Float(1),json.String("1"),json.Integer(0),json.Integer(-1),json.Null{}}) {
        row["capacity"]=bad
        bytes,_:=json.marshal(row,allocator=context.temp_allocator)
        _,valid:=owner_fleet_policy_parse(string(bytes))
        testing.expect(t,!valid)
    }
    for bad in ([5]string{"[]","[\"Worker\"]","[\"worker\",\"worker\"]","[\"*\"]","{\"worker\":true}"}) {
        row["capacity"]=json.Integer(1)
        row["roles_json"]=json.String(bad)
        bytes,_:=json.marshal(row,allocator=context.temp_allocator)
        _,valid:=owner_fleet_policy_parse(string(bytes))
        testing.expect(t,!valid)
    }
}

@(test)
owner_content_json_unicode_does_not_relax_authority_envelopes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for raw in ([2]string{`{"name":"模型🚀"}`,`{"name":"\ud83d\ude80"}`}) {
        _,content:=owner_content_document(raw)
        _,authority:=owner_request_document(raw)
        testing.expect(t,content && !authority)
    }
    for raw in ([8]string{`{"x":1,"\u0078":2}`,`{"x":{"a":1,"a":2}}`,`{"x":"\ud800"}`,`{"x":"\udc00"}`,`{"x":"\ud800\u0041"}`,`{"x":"\'"}`,`{"x":1,}`,`{"x":1}x`}) {
        _,valid:=owner_content_document(raw)
        testing.expect(t,!valid,raw)
    }
}


@(test)
owner_content_json_rejects_invalid_utf8_and_hex_escapes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    for raw in ([4]string{"{\"name\":\"\xff\"}","{\"name\":\"\xc0\x80\"}","{\"name\":\"\\u+000\"}","{\"name\":\"\\u-001\"}"}) {
        _,valid:=owner_content_document(raw)
        testing.expect(t,!valid)
    }
}
