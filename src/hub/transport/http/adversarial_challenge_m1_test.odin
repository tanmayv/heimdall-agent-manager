package http

import base64 "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"

// ===========================================================================
// ADVERSARIAL STRESS TEST SUITE: MILESTONE M1
// Empirical verification of edge cases, boundary conditions, and stress inputs.
// ===========================================================================

// ---------------------------------------------------------------------------
// Category 1: Trimming Edge Cases
// ---------------------------------------------------------------------------

@(test)
test_adv_trim_empty_string :: proc(t: ^testing.T) {
	got := _shell_screen_trim_trailing_blank_rows("")
	defer delete(got)
	testing.expect_value(t, got, "")
}

@(test)
test_adv_trim_pure_whitespace_variations :: proc(t: ^testing.T) {
	cases := []string{
		" ",
		"    ",
		"\t",
		"\t\t\t",
		" \t \t ",
		"\r",
		"\r\r\r",
		"\n",
		"\n\n\n",
		"\r\n",
		"\r\n\r\n",
		"   \n   \n   ",
		"\t\t\n  \t  \n\r\n",
		" \r \n \t \r\n",
	}

	for c in cases {
		got := _shell_screen_trim_trailing_blank_rows(c)
		defer delete(got)
		testing.expect_value(t, got, "")
	}
}

@(test)
test_adv_trim_prompt_with_trailing_spaces :: proc(t: ^testing.T) {
	// 1. Single line with spaces at end
	s1 := "user@host:~$ "
	got1 := _shell_screen_trim_trailing_blank_rows(s1)
	defer delete(got1)
	testing.expect_value(t, got1, "user@host:~$ ")

	// 2. Single line with multiple trailing spaces followed by 50 blank rows
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "sh-5.2$    ")
	for _ in 0 ..< 50 {
		append(&lines, "")
	}
	s2 := strings.join(lines[:], "\n")
	defer delete(s2)
	got2 := _shell_screen_trim_trailing_blank_rows(s2)
	defer delete(got2)
	testing.expect_value(t, got2, "sh-5.2$    ")

	// 3. Prompt ending with tab
	s3 := "prompt>\t\n\n\n"
	got3 := _shell_screen_trim_trailing_blank_rows(s3)
	defer delete(got3)
	testing.expect_value(t, got3, "prompt>\t")
}

@(test)
test_adv_trim_interior_blank_lines_preservation :: proc(t: ^testing.T) {
	// Multiple consecutive interior blank lines
	input := "Header\n\n\n\nBody line 1\n\nBody line 2\n\n\n"
	got := _shell_screen_trim_trailing_blank_rows(input)
	defer delete(got)
	testing.expect_value(t, got, "Header\n\n\n\nBody line 1\n\nBody line 2")

	// Interior blank lines with spaces and tabs
	input2 := "Header\n   \n\t\t\nBody\n  \n  "
	got2 := _shell_screen_trim_trailing_blank_rows(input2)
	defer delete(got2)
	testing.expect_value(t, got2, "Header\n   \n\t\t\nBody")
}

@(test)
test_adv_trim_crlf_vs_lf_line_endings :: proc(t: ^testing.T) {
	// Pure CRLF input
	input_crlf := "line 1\r\nline 2\r\n\r\n\r\n"
	got_crlf := _shell_screen_trim_trailing_blank_rows(input_crlf)
	defer delete(got_crlf)
	testing.expect_value(t, got_crlf, "line 1\r\nline 2")

	// Mixed LF and CRLF
	input_mixed := "line 1\nline 2\r\nline 3\n\r\n\n"
	got_mixed := _shell_screen_trim_trailing_blank_rows(input_mixed)
	defer delete(got_mixed)
	testing.expect_value(t, got_mixed, "line 1\nline 2\r\nline 3")

	// CR without LF (carriage return within line or before newline)
	input_cr := "overwrite\rprompt> \n\n"
	got_cr := _shell_screen_trim_trailing_blank_rows(input_cr)
	defer delete(got_cr)
	testing.expect_value(t, got_cr, "overwrite\rprompt> ")
}

@(test)
test_adv_trim_unicode_and_special_characters :: proc(t: ^testing.T) {
	// Unicode box drawing and emojis
	input := "┌───┐\n│ 😀 │\n└───┘\n\n\n"
	got := _shell_screen_trim_trailing_blank_rows(input)
	defer delete(got)
	testing.expect_value(t, got, "┌───┐\n│ 😀 │\n└───┘")

	// Japanese full-width space U+3000 on trailing line
	// Note: U+3000 is 3 bytes (0xE3, 0x80, 0x80) - treated as non-whitespace by ASCII byte scanner
	input_cjk := "line 1\n\u3000\n"
	got_cjk := _shell_screen_trim_trailing_blank_rows(input_cjk)
	defer delete(got_cjk)
	testing.expect_value(t, got_cjk, "line 1\n\u3000")
}

// ---------------------------------------------------------------------------
// Category 2: ANSI CUP Repaint & Coordinate Edge Cases
// ---------------------------------------------------------------------------

@(test)
test_adv_repaint_origin_coordinate :: proc(t: ^testing.T) {
	// (0, 0) -> ANSI 1-indexed \x1b[1;1H
	got := _shell_screen_repaint_text("hello", 0, 0)
	defer delete(got)
	testing.expect_value(t, got, "\x1b[2J\x1b[Hhello\x1b[1;1H")
}

@(test)
test_adv_repaint_large_and_extreme_coordinates :: proc(t: ^testing.T) {
	// (999, 1999) -> \x1b[1000;2000H
	got1 := _shell_screen_repaint_text("grid", 999, 1999)
	defer delete(got1)
	testing.expect_value(t, got1, "\x1b[2J\x1b[Hgrid\x1b[1000;2000H")

	// Max u16 boundary (65535, 65535) -> \x1b[65536;65536H
	got2 := _shell_screen_repaint_text("grid", 65535, 65535)
	defer delete(got2)
	testing.expect_value(t, got2, "\x1b[2J\x1b[Hgrid\x1b[65536;65536H")
}

@(test)
test_adv_repaint_negative_coordinates :: proc(t: ^testing.T) {
	// Both negative
	got1 := _shell_screen_repaint_text("grid", -1, -1)
	defer delete(got1)
	testing.expect_value(t, got1, "\x1b[2J\x1b[Hgrid")

	// Extremely negative
	got2 := _shell_screen_repaint_text("grid", -9999, -500)
	defer delete(got2)
	testing.expect_value(t, got2, "\x1b[2J\x1b[Hgrid")

	// Mixed: valid row, negative col -> CUP omitted
	got3 := _shell_screen_repaint_text("grid", 5, -1)
	defer delete(got3)
	testing.expect_value(t, got3, "\x1b[2J\x1b[Hgrid")

	// Mixed: negative row, valid col -> CUP omitted
	got4 := _shell_screen_repaint_text("grid", -1, 10)
	defer delete(got4)
	testing.expect_value(t, got4, "\x1b[2J\x1b[Hgrid")
}

@(test)
test_adv_repaint_on_empty_and_whitespace_pane :: proc(t: ^testing.T) {
	// Empty pane with coordinates
	got1 := _shell_screen_repaint_text("", 0, 5)
	defer delete(got1)
	testing.expect_value(t, got1, "\x1b[2J\x1b[H\x1b[1;6H")

	// Whitespace-only pane with coordinates: trimmed to empty body, homes and positions cursor
	got2 := _shell_screen_repaint_text("   \n\n  \t  \n", 0, 0)
	defer delete(got2)
	testing.expect_value(t, got2, "\x1b[2J\x1b[H\x1b[1;1H")
}

// ---------------------------------------------------------------------------
// Category 3: JSON Frame Serialization Extremes
// ---------------------------------------------------------------------------

@(test)
test_adv_frame_json_extreme_coordinates :: proc(t: ^testing.T) {
	// Origin (0, 0)
	frame0 := shell_stream_screen_frame_json("ABC", 0, 0)
	defer delete(frame0)
	testing.expect_value(t, frame0, "{\"type\":\"screen\",\"screen_b64\":\"ABC\",\"cursor_row\":0,\"cursor_col\":0}")

	// Large coordinates
	frame_lg := shell_stream_screen_frame_json("ABC", 65535, 32768)
	defer delete(frame_lg)
	testing.expect_value(t, frame_lg, "{\"type\":\"screen\",\"screen_b64\":\"ABC\",\"cursor_row\":65535,\"cursor_col\":32768}")

	// Negative coordinates omitted
	frame_neg := shell_stream_screen_frame_json("ABC", -10, -20)
	defer delete(frame_neg)
	testing.expect_value(t, frame_neg, "{\"type\":\"screen\",\"screen_b64\":\"ABC\"}")
}

// ---------------------------------------------------------------------------
// Category 4: High-Volume & Chunking Stress Test
// ---------------------------------------------------------------------------

@(test)
test_adv_high_volume_blank_lines_stress :: proc(t: ^testing.T) {
	// 5,000 blank lines after a prompt
	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, "fast_prompt$ ")
	for _ in 0 ..< 5000 {
		append(&lines, "")
	}
	huge_pane := strings.join(lines[:], "\n")
	defer delete(huge_pane)

	got := _shell_screen_repaint_text(huge_pane, 0, 13)
	defer delete(got)

	// Must be trimmed cleanly in O(N) without hanging or memory explosion
	testing.expect_value(t, got, "\x1b[2J\x1b[Hfast_prompt$ \x1b[1;14H")
}

@(test)
test_adv_chunked_snapshot_with_cursor_cup :: proc(t: ^testing.T) {
	// Generate a screen payload exceeding SHELL_SCREEN_CHUNK_DECODED_BYTES (32 KiB)
	// Say 500 lines of 100 characters each (~50 KB)
	repeat_x := strings.repeat("x", 85, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 500 {
		append(&lines, fmt.tprintf("Line %04d: %s", i, repeat_x))
	}
	pane := strings.join(lines[:], "\n")
	defer delete(pane)

	cursor_r := 499
	cursor_c := 20
	repaint := _shell_screen_repaint_text(pane, cursor_r, cursor_c)
	defer delete(repaint)

	// Verify repaint is > 32KB
	testing.expect(t, len(repaint) > SHELL_SCREEN_CHUNK_DECODED_BYTES, "repaint must exceed 32KB")

	// Walk chunks using _shell_screen_chunk_end and verify invariants
	chunk_count := 0
	offset := 0
	saw_cup_in_last_chunk := false

	expected_cup := fmt.tprintf("\x1b[%d;%dH", cursor_r + 1, cursor_c + 1)

	for offset < len(repaint) {
		chunk_count += 1
		end := _shell_screen_chunk_end(repaint, offset)
		chunk := repaint[offset:end]

		if chunk_count == 1 {
			// First chunk must lead with repaint prefix
			testing.expect(t, strings.has_prefix(chunk, SHELL_SCREEN_REPAINT_PREFIX), "first chunk has prefix")
		}

		if end == len(repaint) {
			// Final chunk must end with ANSI CUP
			if strings.has_suffix(chunk, expected_cup) {
				saw_cup_in_last_chunk = true
			}
		}

		offset = end
	}

	testing.expect(t, chunk_count >= 2, "must be split into at least 2 chunks")
	testing.expect(t, saw_cup_in_last_chunk, "final chunk must contain the ANSI CUP sequence")
}

// ---------------------------------------------------------------------------
// Category 5: End-to-End Socket Malformed & Adversarial Reply Frame Parsing
// ---------------------------------------------------------------------------

@(test)
test_adv_write_screen_frame_malformed_json_reply :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if listen_err != nil do testing.fail_now(t, "could not listen on loopback")
	defer net.close(listener)
	endpoint, _ := net.bound_endpoint(listener)
	client, _ := net.dial_tcp(endpoint)
	defer net.close(client)
	hub, _, _ := net.accept_tcp(listener)
	defer net.close(hub)

	// 1. Reply missing "output" field
	bad_reply1 := "{\"ok\":true,\"unchanged\":false,\"cursor_row\":0,\"cursor_col\":8}"
	testing.expect(t, !_shell_stream_write_screen_frame(nil, "", hub, bad_reply1), "missing output writes nothing")

	// 2. Reply with empty output string
	bad_reply2 := "{\"ok\":true,\"output\":\"\",\"cursor_row\":0,\"cursor_col\":8}"
	testing.expect(t, !_shell_stream_write_screen_frame(nil, "", hub, bad_reply2), "empty output writes nothing")

	// 3. Reply with missing coordinates defaults to -1 (no CUP, no json coords)
	no_coords_reply := "{\"ok\":true,\"output\":\"my prompt> \"}"
	testing.expect(t, _shell_stream_write_screen_frame(nil, "", hub, no_coords_reply), "write succeeds without coords")

	buf: [512]byte
	n, _ := net.recv_tcp(client, buf[:])
	testing.expect(t, n > 0, "client receives frame")
	got_str := string(buf[:n])
	testing.expect(t, !strings.contains(got_str, "cursor_row"), "cursor_row omitted when absent from reply")
	testing.expect(t, !strings.contains(got_str, "cursor_col"), "cursor_col omitted when absent from reply")
}
