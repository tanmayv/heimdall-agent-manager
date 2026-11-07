package contracts

import "core:testing"

@(test)
original_content_spans_preserve_received_parent_entries_and_integer_lexemes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    raw:=` { "pay\u006coad" : { "run" : [ { "n":9007199254740993, "text":"雪\u0020x" }, {"n":1e3} ], "stop":[ "a\u0062", "c" ] } } `
    payload,ok:=owner_content_member_bytes(raw,"payload");testing.expect(t,ok)
    testing.expect_value(t,payload,`{ "run" : [ { "n":9007199254740993, "text":"雪\u0020x" }, {"n":1e3} ], "stop":[ "a\u0062", "c" ] }`)
    run,run_ok:=owner_content_member_bytes(payload,"run");testing.expect(t,run_ok)
    entries,entries_ok:=owner_content_array_bytes(run)
    if !testing.expect(t,entries_ok && len(entries)==2) do return
    testing.expect_value(t,entries[0],`{ "n":9007199254740993, "text":"雪\u0020x" }`)
    testing.expect_value(t,entries[1],`{"n":1e3}`)
    stop,stop_ok:=owner_content_member_bytes(payload,"stop");testing.expect(t,stop_ok)
    stops,stops_ok:=owner_content_array_bytes(stop)
    if testing.expect(t,stops_ok && len(stops)==2) {
        testing.expect_value(t,stops[0],`"a\u0062"`)
        testing.expect_value(t,stops[1],`"c"`)
    }
    _,ok=owner_content_member_bytes(`{"payload":{},"pay\u006coad":{}}`,"payload")
    testing.expect(t,!ok,"decoded duplicate key invalidates entire document before extraction")
    _,ok=owner_content_member_bytes(`{"payload":{},"tail":`,"payload")
    testing.expect(t,!ok,"valid prefix cannot conceal malformed tail")
    _,ok=owner_content_array_bytes(`[{},]`);testing.expect(t,!ok)
    empty,empty_ok:=owner_content_array_bytes(`[]`);testing.expect(t,empty_ok && len(empty)==0)
}
