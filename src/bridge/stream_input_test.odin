package main

import "core:encoding/json"
import "core:testing"
import contracts "odin_test:contracts"

@(test)
test_stream_input_coordinates_are_viewport_relative :: proc(t: ^testing.T) {
	raw := `{"metadata":{"deviceWidth":1600,"deviceHeight":840,"offsetTop":40,"pageScaleFactor":2.0,"scrollOffsetX":100,"scrollOffsetY":600}}`
	params: json.Object
	if !testing.expect(t, json.unmarshal(transmute([]byte)raw, &params, allocator = context.temp_allocator) == nil) do return
	f := stream_input_frame(params)
	x, y, ok := stream_input_viewport(f, 0.5, 0.5)
	testing.expect(t, ok)
	testing.expect_value(t, x, 400.0)
	testing.expect_value(t, y, 190.0)
	_, top, _ := stream_input_viewport(f, 0.5, 0.0)
	testing.expect_value(t, top, 0.0)
	_, _, missing := stream_input_viewport(stream_input_frame(nil), 0.5, 0.5)
	testing.expect(t, !missing)
}

@(test)
test_stream_input_coalesces_moves_without_swallowing_drag_boundaries :: proc(t: ^testing.T) {
	q: Stream_Input_Queue
	defer stream_input_clear(&q)
	first: []contracts.Stream_Input_Event = {
		contracts.Stream_Input_Pointer{action = "down", x = 0.1},
		contracts.Stream_Input_Pointer{action = "move", button = -1, x = 0.2},
	}
	second: []contracts.Stream_Input_Event = {
		contracts.Stream_Input_Pointer{action = "move", button = -1, x = 0.3},
		contracts.Stream_Input_Pointer{action = "up", x = 0.3},
	}
	stream_input_enqueue(&q, first)
	stream_input_enqueue(&q, second)
	if !testing.expect_value(t, q.count, 3) do return
	testing.expect_value(t, q.events[0].(contracts.Stream_Input_Pointer).action, "down")
	testing.expect_value(t, q.events[1].(contracts.Stream_Input_Pointer).x, 0.3)
	testing.expect_value(t, q.events[2].(contracts.Stream_Input_Pointer).action, "up")
}
