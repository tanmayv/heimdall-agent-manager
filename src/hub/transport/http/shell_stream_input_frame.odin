package http

// Both terminal panes use one explicit payload and encryption flag. The Hub
// validates the envelope and relays ciphertext; only the Bridge decrypts it.
import base64 "core:encoding/base64"
import "core:strings"

Shell_Stream_Input_Kind :: enum { Empty, Plain, Armored, Undecodable }
Shell_Stream_Input :: struct {
	kind: Shell_Stream_Input_Kind,
	plain: string,
	armored: string,
	reason: string,
}

shell_stream_decode_input_frame :: proc(text: string) -> Shell_Stream_Input {
	data := json_string(text, "data_b64")
	defer delete(data)
	encrypted, flag_ok := json_bool_literal(text, "is_encrypted")
	if !flag_ok do return {kind = .Undecodable, reason = "is_encrypted must be a boolean"}
	if data == "" do return {kind = .Empty}
	if len(data) > 64 * 1024 do return {kind = .Undecodable, reason = "input payload exceeds 64 KiB"}
	decoded, err := base64.decode(data)
	if err != nil { if decoded != nil do delete(decoded); return {kind = .Undecodable, reason = "data_b64 must be valid base64"} }
	if encrypted {
		defer delete(decoded)
		if len(decoded) < 28 do return {kind = .Undecodable, reason = "encrypted input is shorter than nonce and tag"}
		return {kind = .Armored, armored = strings.clone(data)}
	}
	return {kind = .Plain, plain = string(decoded)}
}

shell_stream_input_destroy :: proc(frame: ^Shell_Stream_Input) {
	if frame == nil do return
	delete(frame.plain)
	delete(frame.armored)
	frame^ = {}
}
