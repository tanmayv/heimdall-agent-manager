package http

// REQ-PANE-INPUT-1/5: THE one decoder for the terminal `"input"` WebSocket frame.
//
// WHY THIS EXISTS. Two panes consume the identical input frame — the shells pane
// (shell_session_handlers.odin) and the agent pane (agent_instance_handlers.odin) — and
// the contract was spelled out in only one of them. The agent pane's copy had no
// `vault:v1:` branch and never read `enc_b64` at all, so with the vault UNLOCKED every
// keystroke the composer sent (useAgentStream.ts:385-409 encrypts and sends
// `{enc_b64, data_b64: "vault:v1:"+enc_b64}`) hit a base64.decode of a string that is not
// base64, failed, and was dropped with no log: a TOTAL input outage that only reproduced
// while the vault was unlocked, which is why it shipped. That is the same class of
// two-pane drift REQ-SHELL-61 fixed for the resize snapshot, so the fix is the same shape:
// the predicate lives here once and both handlers consult it.
//
// WHAT THE HUB DOES NOT DO: decrypt. The Hub holds no plaintext vault key — it stores only
// `encrypted_vault_key` (hub/domain/user_vault.odin) — so an armored payload is RELAYED to
// the bridge, which owns the key and decrypts it in bridge_hub_handle_shell_pty_input
// (src/bridge/hub_runtime_client.odin:1327-1395), or rejects it there and logs. Keystrokes
// are end-to-end encrypted between the browser and the bridge by design.
//
// REQ-PANE-INPUT-6: there is no permissive default here. A frame that cannot be classified
// comes back as `.Undecodable` with a reason for the caller to log, and ciphertext is only
// ever handed to the bridge as `armored` — never as the plaintext the pty is fed.

import base64 "core:encoding/base64"
import "core:strings"
import domain "odin_test:hub/domain"

Shell_Stream_Input_Kind :: enum {
	Empty, // the frame carried no payload at all; nothing to forward.
	Plain, // `plain` is the user's actual keystrokes.
	Armored, // `armored` is vault ciphertext for the bridge to decrypt.
	Undecodable, // malformed; `reason` says how. MUST be logged, never forwarded.
}

// Shell_Stream_Input owns every non-empty string field; release it with
// shell_stream_input_destroy.
Shell_Stream_Input :: struct {
	kind:    Shell_Stream_Input_Kind,
	plain:   string, // plaintext keystrokes (kind == .Plain)
	armored: string, // ciphertext to relay as enc_b64 (kind == .Armored)
	enc_b64: string, // the frame's raw enc_b64, relayed alongside plaintext when both are present
	reason:  string, // static literal; why the frame is undecodable (kind == .Undecodable)
}

// shell_stream_decode_input_frame classifies one `"input"` frame body.
//
// The precedence is the wire contract and is deliberately ordered:
//  1. an armored `data_b64` means the encrypted path, and `enc_b64` is preferred as the
//     payload because it is the bare ciphertext the bridge wants (the armored `data_b64`
//     is the same bytes behind a prefix, kept for older clients);
//  2. a plain `data_b64` is base64 keystrokes; any `enc_b64` rides along untouched so the
//     bridge can still prefer it when a vault key is active;
//  3. a `data_b64` that is neither armored nor valid base64 falls back to `enc_b64` if the
//     frame carried one, and is otherwise undecodable — NOT silently discarded;
//  4. with no `data_b64`, the legacy `data` field is used, armor-checked the same way.
shell_stream_decode_input_frame :: proc(text: string) -> Shell_Stream_Input {
	enc_b64 := json_string(text, "enc_b64")
	data_b64 := json_string(text, "data_b64")
	defer delete(data_b64)

	if strings.has_prefix(data_b64, domain.VAULT_ARMOR_PREFIX) {
		if enc_b64 != "" do return Shell_Stream_Input{kind = .Armored, armored = enc_b64}
		return Shell_Stream_Input{kind = .Armored, armored = strings.clone(data_b64)}
	}

	if data_b64 != "" {
		decoded, decode_err := base64.decode(data_b64)
		if decode_err == nil && decoded != nil {
			return Shell_Stream_Input{kind = .Plain, plain = string(decoded), enc_b64 = enc_b64}
		}
		if decoded != nil do delete(decoded)
		if enc_b64 != "" do return Shell_Stream_Input{kind = .Armored, armored = enc_b64}
		return Shell_Stream_Input {
			kind = .Undecodable,
			reason = "data_b64 is neither vault-armored nor valid base64, and the frame carried no enc_b64",
		}
	}

	data := json_string(text, "data")
	if strings.has_prefix(data, domain.VAULT_ARMOR_PREFIX) {
		if enc_b64 != "" {
			delete(data)
			return Shell_Stream_Input{kind = .Armored, armored = enc_b64}
		}
		return Shell_Stream_Input{kind = .Armored, armored = data}
	}
	if data != "" do return Shell_Stream_Input{kind = .Plain, plain = data, enc_b64 = enc_b64}
	delete(data)

	if enc_b64 != "" do return Shell_Stream_Input{kind = .Armored, armored = enc_b64}
	delete(enc_b64)
	return Shell_Stream_Input{kind = .Empty}
}

shell_stream_input_destroy :: proc(frame: ^Shell_Stream_Input) {
	if frame == nil do return
	if frame.plain != "" do delete(frame.plain)
	if frame.armored != "" do delete(frame.armored)
	if frame.enc_b64 != "" do delete(frame.enc_b64)
	frame^ = Shell_Stream_Input{}
}
