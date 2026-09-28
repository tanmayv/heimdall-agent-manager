package main

// REQ-VAULT-2 — source 4 of ctl_read_vault_key: the local bridge, via
// agent.vault.get.
//
// Why this file exists. Sources 1-3 (--vault-key, $HEIMDALL_VAULT_KEY, the key
// file) are all fixed at or before the moment an agent is spawned. An agent spawned
// before the operator ran `ham-ctl vault set-key` therefore could never decrypt
// anything for the rest of its life. Source 4 asks the bridge, which holds the key
// live, so the agent's NEXT invocation succeeds with no respawn.
//
// Two things are tested at different depths:
//   - the parsing/validation rules, against ctl_vault_key_from_response directly,
//     so every malformed-response shape can be enumerated cheaply;
//   - the real socket path, against an in-process TCP bridge that speaks the actual
//     JSONL protocol, so ctl_agent_local_call is genuinely exercised rather than
//     assumed. This is also what lets the short-circuit tests below be meaningful:
//     the fake bridge WOULD hand back a valid key, so a test that ends with "no key"
//     proves the bridge was never consulted.
//
// Every test that can observe key state opens the REQ-VAULT-4 sandbox, so none of
// them reads or writes the operator's real ~/.config/heimdall/vault_key.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import cfg_lib "odin_test:lib/config"

VAULT_BRIDGE_TEST_KEY :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// ── in-process fake bridge ────────────────────────────────────────────────────

// Ctl_Vault_Fake_Bridge is a one-shot TCP listener that returns a canned response
// line to the first client, then stops. TCP rather than a unix socket because
// ctl_agent_local_call supports `tcp:` endpoints (ctl_agent_send_tcp) and core:net
// gives us a listener without hand-rolling sockaddr_un.
Ctl_Vault_Fake_Bridge :: struct {
	listener: net.TCP_Socket,
	endpoint: string, // "tcp:127.0.0.1:<port>", ready for HEIMDALL_BRIDGE_ENDPOINT
	response: string, // written verbatim, newline-terminated by the writer
	got_call: bool,   // set true only once a real request line arrives

	// The request is kept in a fixed buffer rather than a cloned string: it is
	// written on the server thread and read on the test thread, and an inline buffer
	// avoids allocating on one thread and freeing on the other.
	request_buf: [8192]byte,
	request_len: int,

	t: ^thread.Thread,
}

// ctl_vault_fake_bridge_request returns the request line the client sent.
ctl_vault_fake_bridge_request :: proc(fb: ^Ctl_Vault_Fake_Bridge) -> string {
	return string(fb.request_buf[:fb.request_len])
}

// Binds an ephemeral port on loopback and serves `response` to one client.
ctl_vault_fake_bridge_start :: proc(response: string) -> (^Ctl_Vault_Fake_Bridge, bool) {
	fb := new(Ctl_Vault_Fake_Bridge)
	fb.response = response

	// Port 0 lets the OS pick a free port, so concurrent test runs cannot collide.
	listener, bind_err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if bind_err != nil {
		free(fb)
		return nil, false
	}
	fb.listener = listener

	bound, addr_err := net.bound_endpoint(listener)
	if addr_err != nil {
		net.close(listener)
		free(fb)
		return nil, false
	}
	fb.endpoint = fmt.aprintf("tcp:127.0.0.1:%d", bound.port)

	fb.t = thread.create_and_start_with_poly_data(fb, proc(fb: ^Ctl_Vault_Fake_Bridge) {
		client, _, accept_err := net.accept_tcp(fb.listener)
		if accept_err != nil do return
		defer net.close(client)

		// got_call is set only once a REQUEST actually arrives, never merely on
		// connect. ctl_vault_fake_bridge_stop below dials this listener to unblock
		// accept() and sends nothing, and that wakeup must not be mistaken for a
		// real call — several tests assert got_call == false.
		n, recv_err := net.recv_tcp(client, fb.request_buf[:])
		if recv_err != nil || n <= 0 do return
		fb.request_len = n
		fb.got_call = true

		line := strings.concatenate({fb.response, "\n"})
		defer delete(line)
		_, _ = net.send_tcp(client, transmute([]byte)line)
	})
	return fb, fb.t != nil
}

// Tests that assert the bridge was NOT consulted leave the server thread parked in a
// blocking accept(). Closing the listener fd does NOT reliably wake accept() in
// another thread on Linux, so joining first would deadlock. Dialling the listener
// once hands accept() a connection, the thread sees a zero-length read and exits,
// and the join is then guaranteed to return.
ctl_vault_fake_bridge_stop :: proc(fb: ^Ctl_Vault_Fake_Bridge) {
	if fb.t != nil {
		if bound, err := net.bound_endpoint(fb.listener); err == nil {
			if wake, dial_err := net.dial_tcp(net.IP4_Loopback, bound.port); dial_err == nil {
				net.close(wake)
			}
		}
		thread.join(fb.t)
		thread.destroy(fb.t)
	}
	net.close(fb.listener)
	delete(fb.endpoint)
	free(fb)
}

// bridge_local_response_data's envelope shape, so the fakes match the real bridge.
//
// Built by concatenation, NOT fmt.aprintf: fmt treats '{' as the start of a
// brace-style format verb, so a literal JSON brace inside a FORMAT string renders as
// "%!(MISSING CLOSE BRACE)" and silently produces a corrupt envelope.
ctl_vault_test_ok_envelope :: proc(data_json: string) -> string {
	return strings.concatenate({"{\"v\":1,\"id\":\"ham-ctl-agent\",\"ok\":true,\"data\":", data_json, "}"})
}

// ctl_vault_test_key_data renders a vault.get data object carrying `key`, for the
// same reason, and is freed by the caller.
ctl_vault_test_key_data :: proc(key: string) -> string {
	return strings.concatenate({"{\"key\":\"", key, "\",\"key_length\":64}"})
}

// ── parsing and validation (ctl_vault_key_from_response) ──────────────────────

@(test)
test_vault_bridge_response_valid_key :: proc(t: ^testing.T) {
	data := ctl_vault_test_key_data(VAULT_BRIDGE_TEST_KEY)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)

	key, ok := ctl_vault_key_from_response(body)
	testing.expect(t, ok, "a valid 64-char hex key from the bridge must be accepted")
	defer if ok do delete(key)
	testing.expect_value(t, key, VAULT_BRIDGE_TEST_KEY)
}

// Uppercase is valid hex and is_valid_hex_key accepts it, so the bridge source must
// too — otherwise a hand-set key would work from the file but not from the bridge.
@(test)
test_vault_bridge_response_accepts_uppercase_key :: proc(t: ^testing.T) {
	upper := "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
	data := ctl_vault_test_key_data(upper)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)

	key, ok := ctl_vault_key_from_response(body)
	testing.expect(t, ok, "uppercase hex from the bridge must be accepted")
	defer if ok do delete(key)
	testing.expect_value(t, key, upper)
}

// The `not_found` envelope the bridge returns when no key is configured
// (src/bridge/agent_api.odin:390). It carries no "key" member at all.
@(test)
test_vault_bridge_response_not_found :: proc(t: ^testing.T) {
	body := "{\"v\":1,\"id\":\"ham-ctl-agent\",\"ok\":false,\"error\":{\"code\":\"not_found\"," +
		"\"message\":\"vault key not configured or permissions invalid\"}}"

	_, ok := ctl_vault_key_from_response(body)
	testing.expect(t, !ok, "a not_found response must resolve to no key, not an error")
}

@(test)
test_vault_bridge_response_malformed_json :: proc(t: ^testing.T) {
	// Each of these must be treated as "no key" rather than crashing: truncated
	// mid-envelope, truncated mid-key, empty, and outright not-JSON.
	cases := []string{
		"",
		"not json at all",
		"{\"v\":1,\"ok\":true,\"data\":{",
		"{\"v\":1,\"ok\":true,\"data\":{\"key\":\"0123456789abcdef",
		"{\"v\":1,\"ok\":true,\"data\":{\"key\":",
		"{\"v\":1,\"ok\":true,\"data\":{\"key\":null}}",
		"{\"v\":1,\"ok\":true,\"data\":{\"key\":12345}}",
	}
	for body, i in cases {
		_, ok := ctl_vault_key_from_response(body)
		testing.expect(t, !ok, fmt.tprintf("malformed response %d must resolve to no key", i))
	}
}

@(test)
test_vault_bridge_response_non_hex_and_wrong_length :: proc(t: ^testing.T) {
	bad := []string{
		"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", // 64 chars, not hex
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg", // one bad char
		"0123456789abcdef",                                                 // too short
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef00", // too long
		"",                                                                 // empty
	}
	for value, i in bad {
		data := strings.concatenate({"{\"key\":\"", value, "\"}"})
		defer delete(data)
		body := ctl_vault_test_ok_envelope(data)
		defer delete(body)
		_, ok := ctl_vault_key_from_response(body)
		testing.expect(t, !ok, fmt.tprintf("invalid key value %d must be rejected", i))
	}
}

// "key_length" must not be mistaken for "key". The extractor matches `"key":"`,
// which cannot match `"key_length":`, but that is worth pinning down since a looser
// match would silently yield a garbage key.
@(test)
test_vault_bridge_response_key_length_alone_is_not_a_key :: proc(t: ^testing.T) {
	body := ctl_vault_test_ok_envelope("{\"key_length\":64}")
	defer delete(body)

	_, ok := ctl_vault_key_from_response(body)
	testing.expect(t, !ok, "key_length alone must not be read as a key")
}

// ── env gating (ctl_vault_key_from_bridge) ────────────────────────────────────

// Hub mode: no endpoint, so source 4 must not even be attempted and behaviour is
// exactly as it was before this change.
@(test)
test_vault_bridge_no_endpoint_configured :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-no-endpoint")
	defer ctl_vault_test_sandbox_close(&sb)

	// The sandbox already captured and cleared both of these and restores them on
	// close, so this test only has to set what it wants.

	os_unset("HEIMDALL_BRIDGE_ENDPOINT")
	os_unset("HEIMDALL_AGENT_TOKEN")
	_, ok := ctl_vault_key_from_bridge()
	testing.expect(t, !ok, "no endpoint configured must mean no key from the bridge")

	// An endpoint with no token is equally unusable and must not be attempted.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", "tcp:127.0.0.1:1")
	os_unset("HEIMDALL_AGENT_TOKEN")
	_, ok_no_token := ctl_vault_key_from_bridge()
	testing.expect(t, !ok_no_token, "an endpoint without a token must mean no key")

	// Present-but-empty must behave as absent, not as a valid endpoint.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", "")
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")
	_, ok_empty := ctl_vault_key_from_bridge()
	testing.expect(t, !ok_empty, "an empty endpoint must mean no key")
}

// An unreachable bridge must be an ordinary "no key", never a crash or an abort.
@(test)
test_vault_bridge_unreachable_endpoint :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-unreachable")
	defer ctl_vault_test_sandbox_close(&sb)

	// The sandbox already captured and cleared both of these and restores them on
	// close, so this test only has to set what it wants.

	// Port 1 on loopback: nothing listens there, so dial fails fast.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", "tcp:127.0.0.1:1")
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")
	_, ok := ctl_vault_key_from_bridge()
	testing.expect(t, !ok, "an unreachable bridge must resolve to no key")

	// A unix socket path that does not exist must behave the same way.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", fmt.tprintf("unix:%s/definitely-absent.sock", sb.dir))
	_, ok_unix := ctl_vault_key_from_bridge()
	testing.expect(t, !ok_unix, "an absent unix socket must resolve to no key")
}

// ── the real socket path, end to end through ctl_read_vault_key ───────────────

// THE HEADLINE CASE: no flag, no env, no key file — exactly an agent spawned before
// the operator set a key — and ctl_read_vault_key still resolves, from the bridge.
@(test)
test_vault_read_key_falls_through_to_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-fallthrough")
	defer ctl_vault_test_sandbox_close(&sb)

	data := ctl_vault_test_key_data(VAULT_BRIDGE_TEST_KEY)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)
	fb, started := ctl_vault_fake_bridge_start(body)
	testing.expect(t, started, "fake bridge must start")
	if !started do return
	defer ctl_vault_fake_bridge_stop(fb)

	// The sandbox already captured and cleared both of these and restores them on
	// close, so this test only has to set what it wants.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", fb.endpoint)
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")

	// The sandbox guarantees no key file and no HEIMDALL_VAULT_KEY, and no args are
	// passed, so sources 1-3 all genuinely fail here.
	key, ok := ctl_read_vault_key(nil)
	testing.expect(t, ok, "with no flag/env/file, the bridge must supply the key")
	defer if ok do delete(key)
	testing.expect_value(t, key, VAULT_BRIDGE_TEST_KEY)

	testing.expect(t, fb.got_call, "the bridge must actually have been called")
	testing.expect(
		t,
		strings.contains(ctl_vault_fake_bridge_request(fb), "agent.vault.get"),
		"the fetch must use the agent.vault.get method",
	)
}

// The file must still WIN over the bridge: source 3 before source 4. The fake bridge
// offers a different key, so reading the file's key proves the ordering.
@(test)
test_vault_file_takes_precedence_over_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-file-precedence")
	defer ctl_vault_test_sandbox_close(&sb)

	file_key := "aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
	ctl_vault_set_key([]string{file_key}, nil)

	bridge_key := "1111222233334444111122223333444411112222333344441111222233334444"
	data := ctl_vault_test_key_data(bridge_key)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)
	fb, started := ctl_vault_fake_bridge_start(body)
	testing.expect(t, started, "fake bridge must start")
	if !started do return
	defer ctl_vault_fake_bridge_stop(fb)

	// The sandbox already captured and cleared both of these and restores them on
	// close, so this test only has to set what it wants.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", fb.endpoint)
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")

	key, ok := ctl_read_vault_key(nil)
	testing.expect(t, ok, "the key file must still resolve")
	defer if ok do delete(key)
	testing.expect_value(t, key, file_key)
	testing.expect(t, !fb.got_call, "a readable key file must not reach the bridge at all")
}

// ── short-circuit preservation (the strictest requirement) ────────────────────

// An explicitly supplied but INVALID --vault-key must reject immediately: not the
// file, not the bridge. The fake bridge here holds a perfectly valid key, so if the
// short-circuit regressed this test would see ok=true and fb.got_call=true.
@(test)
test_vault_invalid_flag_does_not_reach_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-shortcircuit-flag")
	defer ctl_vault_test_sandbox_close(&sb)

	// A VALID key file too, so this also re-proves the flag does not fall through to
	// the file — the original semantics, now with a fourth source behind it.
	good_file_key := "aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
	ctl_vault_set_key([]string{good_file_key}, nil)

	data := ctl_vault_test_key_data(VAULT_BRIDGE_TEST_KEY)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)
	fb, started := ctl_vault_fake_bridge_start(body)
	testing.expect(t, started, "fake bridge must start")
	if !started do return
	defer ctl_vault_fake_bridge_stop(fb)

	// The sandbox already captured and cleared both of these and restores them on
	// close, so this test only has to set what it wants.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", fb.endpoint)
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")

	_, ok := ctl_read_vault_key([]string{"--vault-key", "not_a_valid_hex_key"})
	testing.expect(t, !ok, "an invalid --vault-key must reject immediately")
	testing.expect(t, !fb.got_call, "an invalid --vault-key must NOT reach the bridge")
}

// Same requirement for $HEIMDALL_VAULT_KEY.
@(test)
test_vault_invalid_env_does_not_reach_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-shortcircuit-env")
	defer ctl_vault_test_sandbox_close(&sb)

	good_file_key := "aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
	ctl_vault_set_key([]string{good_file_key}, nil)

	data := ctl_vault_test_key_data(VAULT_BRIDGE_TEST_KEY)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)
	fb, started := ctl_vault_fake_bridge_start(body)
	testing.expect(t, started, "fake bridge must start")
	if !started do return
	defer ctl_vault_fake_bridge_stop(fb)

	// The sandbox already captured and cleared both of these and restores them on
	// close, so this test only has to set what it wants.
	os_set("HEIMDALL_BRIDGE_ENDPOINT", fb.endpoint)
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")

	// The sandbox unset this; set it to something explicitly invalid.
	os_set("HEIMDALL_VAULT_KEY", "invalid_short_hex")
	_, ok := ctl_read_vault_key(nil)
	testing.expect(t, !ok, "an invalid HEIMDALL_VAULT_KEY must reject immediately")
	testing.expect(t, !fb.got_call, "an invalid HEIMDALL_VAULT_KEY must NOT reach the bridge")

	// A VALID env key must also win without consulting the bridge.
	os_set("HEIMDALL_VAULT_KEY", VAULT_BRIDGE_TEST_KEY)
	key2, ok2 := ctl_read_vault_key(nil)
	testing.expect(t, ok2, "a valid env key must resolve")
	defer if ok2 do delete(key2)
	testing.expect(t, !fb.got_call, "a valid env key must not reach the bridge either")
}

// ── env helpers ───────────────────────────────────────────────────────────────
// Local to this file so it adds nothing to vault_test.odin, which REQ-VAULT-4 owns.
// These capture PRESENCE as well as value, for the same reason the REQ-VAULT-4
// sandbox does: restoring an absent variable as "" would turn "unset" into "set but
// empty" for every test that runs afterwards.


// ── source 3 failure modes reaching source 4 (the ratified fall-through) ──────
//
// These pin the four branches at vault.odin's source-3 block. They are about the
// KEY FILE, which is a different thing from the bridge-RESPONSE validation tested
// above: here the file is what is broken, and the assertion is that ctl goes on to
// ask the bridge instead of hard-failing.

@(test)
test_vault_bad_permissions_file_falls_through_to_bridge :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("bridge-badperms")
	defer ctl_vault_test_sandbox_close(&sb)

	// A perfectly valid key, but world-readable: source 3 refuses it, as it always
	// has. What is new is that refusing is not the end of the story.
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)
	other := "aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)other) == nil, "write key file")
	_ = posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})

	data := ctl_vault_test_key_data(VAULT_BRIDGE_TEST_KEY)
	defer delete(data)
	body := ctl_vault_test_ok_envelope(data)
	defer delete(body)
	fb, started := ctl_vault_fake_bridge_start(body)
	testing.expect(t, started, "fake bridge must start")
	if !started do return
	defer ctl_vault_fake_bridge_stop(fb)
	os_set("HEIMDALL_BRIDGE_ENDPOINT", fb.endpoint)
	os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")

	key, ok := ctl_read_vault_key(nil)
	testing.expect(t, ok, "a 0644 key file must fall through to the bridge, not hard-fail")
	defer if ok do delete(key)
	// The BRIDGE's key, not the unreadable file's — proof of which source answered.
	testing.expect_value(t, key, VAULT_BRIDGE_TEST_KEY)
	testing.expect(t, fb.got_call, "the bridge must have been consulted")
}

@(test)
test_vault_malformed_file_falls_through_to_bridge :: proc(t: ^testing.T) {
	// Each of these is a 0600 file that source 3 cannot turn into a key: wrong
	// length, non-hex, empty, and outright garbage.
	bad := []string{
		"0123456789abcdef",
		"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
		"",
		"this is not a vault key at all",
	}
	for content, i in bad {
		sync.mutex_lock(&vault_test_mutex)
		sb := ctl_vault_test_sandbox_open("bridge-malformed")

		path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
		testing.expect(t, os.write_entire_file(path, transmute([]byte)content) == nil, "write key file")
		_ = posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), posix.mode_t{.IRUSR, .IWUSR})
		delete(path)

		data := ctl_vault_test_key_data(VAULT_BRIDGE_TEST_KEY)
		body := ctl_vault_test_ok_envelope(data)
		fb, started := ctl_vault_fake_bridge_start(body)
		testing.expect(t, started, "fake bridge must start")
		if started {
			os_set("HEIMDALL_BRIDGE_ENDPOINT", fb.endpoint)
			os_set("HEIMDALL_AGENT_TOKEN", "hlat_tok")

			key, ok := ctl_read_vault_key(nil)
			testing.expect(t, ok, fmt.tprintf("malformed key file %d must fall through to the bridge", i))
			if ok {
				testing.expect_value(t, key, VAULT_BRIDGE_TEST_KEY)
				delete(key)
			}
			testing.expect(t, fb.got_call, fmt.tprintf("bridge must be consulted for malformed file %d", i))
			ctl_vault_fake_bridge_stop(fb)
		}
		delete(body)
		delete(data)

		ctl_vault_test_sandbox_close(&sb)
		sync.mutex_unlock(&vault_test_mutex)
	}
}

// And the complement, so the fall-through cannot be mistaken for "the bridge always
// wins": a VALID key file is used as-is and the bridge is never consulted, even
// though the bridge holds a different key. Already covered by
// test_vault_file_takes_precedence_over_bridge above.

// ── env helpers ───────────────────────────────────────────────────────────────
// Thin wrappers so the intent reads at the call site. Restoring is the sandbox's
// job (ctl_vault_test_sandbox_open/close captures and restores all four of the
// variables that feed ctl_read_vault_key), so these only ever set.

os_set :: proc(name, value: string) {
	_ = os.set_env(name, value)
}

os_unset :: proc(name: string) {
	os.unset_env(name)
}
