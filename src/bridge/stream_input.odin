package main

import "base:runtime"
import "core:encoding/json"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import contracts "odin_test:contracts"
import httpc "odin_test:lib/httpc"
import jsonx "odin_test:lib/jsonx"

STREAM_INPUT_PENDING :: 2 * contracts.STREAM_MAX_INPUT_EVENTS
Stream_Input_Queue :: struct {
	events: [STREAM_INPUT_PENDING]contracts.Stream_Input_Event,
	count: int,
}

stream_input_receive :: proc(raw: string) -> bool {
	if !strings.contains(raw, "\"stream_input\"") do return false
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return true
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	context.temp_allocator = allocator
	input, ok := contracts.stream_decode_input(raw, allocator)
	if !ok {
		// Consume recognized but invalid input without falling through to the
		// generic command dispatcher. Other stream frames keep their route.
		return jsonx.extract_string(raw, "type", top_level_only = true, allocator = allocator) == "stream_input"
	}
	sync.mutex_lock(&stream_mu)
	defer sync.mutex_unlock(&stream_mu)
	live := stream_find_locked(input.stream_id)
	if live == nil || !stream_connected || !live.accepted || !live.attached ||
	   live.worker == nil || live.worker_stop || live.worker_watching || live.reason != "" ||
	   live.reg.expires <= u64(bridge_runtime_now_ms()) ||
	   live.reg.source.kind != contracts.STREAM_SOURCE_BROWSER_TAB { return true }
	stream_input_enqueue(&live.input, input.events)
	return true
}

stream_input_is_move :: proc(event: contracts.Stream_Input_Event) -> bool {
	p, ok := event.(contracts.Stream_Input_Pointer)
	return ok && p.action == "move"
}

// Consecutive moves replace each other even across wire batches. A press,
// release, wheel or key event is an ordering barrier. Reject overload as a
// whole batch so a batch containing both press and release is never split.
stream_input_enqueue :: proc(q: ^Stream_Input_Queue, events: []contracts.Stream_Input_Event) {
	size := q.count
	prev_move := size > 0 && stream_input_is_move(q.events[size - 1])
	for e in events {
		move := stream_input_is_move(e)
		if !move || !prev_move do size += 1
		prev_move = move
	}
	if size > len(q.events) do return
	for e in events {
		if q.count > 0 && stream_input_is_move(q.events[q.count - 1]) && stream_input_is_move(e) {
			stream_input_release(q.events[q.count - 1])
			q.count -= 1
		}
		allocator := runtime.heap_allocator()
		switch v in e {
		case contracts.Stream_Input_Pointer:
			q.events[q.count] = contracts.Stream_Input_Pointer{strings.clone(v.action, allocator), v.button, v.x, v.y, v.buttons}
		case contracts.Stream_Input_Wheel:
			q.events[q.count] = v
		case contracts.Stream_Input_Key:
			q.events[q.count] = contracts.Stream_Input_Key{strings.clone(v.action, allocator), strings.clone(v.key, allocator), strings.clone(v.code, allocator), v.modifiers}
		case contracts.Stream_Input_Text:
			q.events[q.count] = contracts.Stream_Input_Text{strings.clone(v.text, allocator)}
		}
		q.count += 1
	}
}

stream_input_release :: proc(event: contracts.Stream_Input_Event) {
	allocator := runtime.heap_allocator()
	switch e in event {
	case contracts.Stream_Input_Pointer: delete(e.action, allocator)
	case contracts.Stream_Input_Wheel:
	case contracts.Stream_Input_Key:
		delete(e.action, allocator)
		delete(e.key, allocator)
		delete(e.code, allocator)
	case contracts.Stream_Input_Text: delete(e.text, allocator)
	}
}

stream_input_clear :: proc(q: ^Stream_Input_Queue) {
	for e in q.events[:q.count] do stream_input_release(e)
	q^ = {}
}

Stream_Input_Frame :: struct {
	width, height, top, scale, scroll_x, scroll_y: f64,
	valid: bool,
}

stream_input_number :: proc(o: json.Object, field: string) -> f64 {
	#partial switch n in o[field] {
	case json.Integer: return f64(n)
	case json.Float: return f64(n)
	}
	return math.nan_f64()
}

stream_input_frame :: proc(params: json.Object) -> (frame: Stream_Input_Frame) {
	m, ok := params["metadata"].(json.Object)
	if !ok do return
	frame = {stream_input_number(m, "deviceWidth"), stream_input_number(m, "deviceHeight"),
		stream_input_number(m, "offsetTop"), stream_input_number(m, "pageScaleFactor"),
		stream_input_number(m, "scrollOffsetX"), stream_input_number(m, "scrollOffsetY"), false}
	frame.valid = frame.width > 0 && frame.height > 0 && frame.scale > 0 &&
		frame.top >= 0 && frame.top < frame.height &&
		!math.is_inf(frame.width) && !math.is_inf(frame.height) && !math.is_inf(frame.scale)
	return
}

// Screencast metadata describes the original surface, not the resized JPEG.
// CDP expects main-frame viewport CSS coordinates. The document scroll origin
// is deliberately not added: Chromium applies scroll when it hit-tests.
stream_input_viewport :: proc(f: Stream_Input_Frame, x, y: f64) -> (f64, f64, bool) {
	if !f.valid do return 0, 0, false
	return x * f.width / f.scale, max(0, y * f.height - f.top) / f.scale, true
}

// Chromium's hit-testing and input acknowledgement are asynchronous. Keep
// one input command in flight so a move cannot overtake a press and a text
// commit cannot overtake a click. Frames and frame ACKs still flow normally.
stream_cdp_drain_input :: proc(conn: ^httpc.WebSocket, capture: ^Stream_CDP_Capture) {
	if capture.input_id != 0 {
		if time.tick_since(capture.input_sent) < 750 * time.Millisecond do return
		capture.input_id = 0
	}
	live := capture.live
	event: contracts.Stream_Input_Event
	sync.mutex_lock(&stream_mu)
	if live.attached && !live.worker_stop && capture.input_frame.valid && live.input.count > 0 &&
	   live.reg.expires > u64(bridge_runtime_now_ms()) {
		q := &live.input
		event = q.events[0]
		q.count -= 1
		copy(q.events[:q.count], q.events[1:q.count + 1])
		q.events[q.count] = nil
	}
	sync.mutex_unlock(&stream_mu)
	if event == nil do return
	defer stream_input_release(event)
	if stream_cdp_dispatch_input(conn, capture, event) {
		capture.input_id = capture.request_id
		capture.input_sent = time.tick_now()
	}
}

// This uses only the already attached session. The Bridge issues no explicit
// focus or tab activation command for input.
stream_cdp_dispatch_input :: proc(conn: ^httpc.WebSocket, capture: ^Stream_CDP_Capture, event: contracts.Stream_Input_Event) -> bool {
	capture.request_id += 1
	id, session := capture.request_id, capture.session
	switch e in event {
	case contracts.Stream_Input_Pointer:
		x, y, ok := stream_input_viewport(capture.input_frame, e.x, e.y)
		if !ok do return true
		buttons := [?]string{"left", "middle", "right", "back", "forward"}
		masks := [?]int{1, 4, 2, 8, 16}
		button, kind, clicks := "none", "mouseMoved", 0
		if e.action == "down" {
			button, kind, clicks = buttons[e.button], "mousePressed", 1
			capture.input_buttons |= masks[e.button]
		} else if e.action == "up" {
			button, kind, clicks = buttons[e.button], "mouseReleased", 1
			capture.input_buttons &~= masks[e.button]
		}
		if held, supplied := e.buttons.?; supplied do capture.input_buttons = held
		return stream_cdp_command(conn, id, session, "Input.dispatchMouseEvent",
			struct {type: string, x, y: f64, button: string, buttons, clickCount: int}{
				kind, x, y, button, capture.input_buttons, clicks})
	case contracts.Stream_Input_Wheel:
		x, y, ok := stream_input_viewport(capture.input_frame, e.x, e.y)
		if !ok do return true
		return stream_cdp_command(conn, id, session, "Input.dispatchMouseEvent",
			struct {type: string, x, y, deltaX, deltaY: f64}{"mouseWheel", x, y, e.dx, e.dy})
	case contracts.Stream_Input_Key:
		kind, text := "keyUp", ""
		if e.action == "down" {
			kind = "rawKeyDown"
			// Text commits from IME use insertText. Ordinary printable
			// keydowns carry their character unless used as a shortcut.
			ch, width := utf8.decode_rune_in_string(e.key)
			if e.modifiers & 7 == 0 && width == len(e.key) && ch >= 32 && ch != 127 {
				kind, text = "keyDown", e.key
			}
			if e.key == "Enter" && e.modifiers & 7 == 0 do kind, text = "keyDown", "\r"
		}
		return stream_cdp_command(conn, id, session, "Input.dispatchKeyEvent",
			struct {type, key, code, text: string, modifiers, windowsVirtualKeyCode: int}{
				kind, e.key, e.code, text, e.modifiers, stream_input_virtual_key(e.key, e.code)})
	case contracts.Stream_Input_Text:
		return stream_cdp_command(conn, id, session, "Input.insertText", struct {text: string}{e.text})
	}
	return true
}

stream_input_virtual_key :: proc(key, code: string) -> int {
	if len(code) == 4 && strings.has_prefix(code, "Key") && code[3] >= 'A' && code[3] <= 'Z' do return int(code[3])
	if len(code) == 6 && strings.has_prefix(code, "Digit") && code[5] >= '0' && code[5] <= '9' do return int(code[5])
	switch key {
	case "Backspace": return 8
	case "Tab": return 9
	case "Enter": return 13
	case "Shift": return 16
	case "Control": return 17
	case "Alt": return 18
	case "Escape": return 27
	case " ": return 32
	case "PageUp": return 33
	case "PageDown": return 34
	case "End": return 35
	case "Home": return 36
	case "ArrowLeft": return 37
	case "ArrowUp": return 38
	case "ArrowRight": return 39
	case "ArrowDown": return 40
	case "Delete": return 46
	}
	return 0
}
