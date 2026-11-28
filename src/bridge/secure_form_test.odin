#+build !windows
package main

import "core:crypto/ecdsa"
import "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import ws "odin_test:lib/ws"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "odin_test:contracts"
import vault "odin_test:lib/vault"

secure_form_test_waiter :: proc() -> Secure_Form_Waiter_State {
	return {binding = {request_id = "request", instance = "caller"}, generation = "2",
		register_started = 100, form_deadline = 90_000, attempt = {1, false, .Unknown}}
}

@(test)
test_secure_form_immediate_terminal_response_decodes :: proc(t: ^testing.T) {
	codes := [?]contracts.Secure_Form_Exit{.Unauthorized, .Not_Delivered, .Retention_Expired}
	for code in codes {
		raw := secure_form_local_response("call", code)
		defer delete(raw)
		reply: struct {
			v: int,
			id: string,
			ok: bool,
			data: struct {terminal: bool, code: int},
		}
		err := json.unmarshal_string(raw, &reply, allocator = context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect(t, reply.v == 1 && reply.id == "call" && reply.ok &&
			reply.data.terminal && reply.data.code == int(code))
	}
}

@(test)
test_secure_form_waiter_registration_fence :: proc(t: ^testing.T) {
	s := secure_form_test_waiter()
	ack := contracts.Secure_Form_Ack{1, "request", "1", "pending", nil}
	testing.expect(t, !secure_form_waiter_register_ack(&s, ack, 150))
	testing.expect(t, !secure_form_waiter_consume(&s, 151, 152))
	ack.generation = "2"
	testing.expect(t, !secure_form_waiter_register_ack(&s, ack, 10_100))
	testing.expect(t, s.attempt.terminal && s.attempt.code == .Not_Delivered)
}

@(test)
test_secure_form_waiter_transition_winners :: proc(t: ^testing.T) {
	s := secure_form_test_waiter()
	ack := contracts.Secure_Form_Ack{1, "request", "2", "pending", nil}
	testing.expect(t, secure_form_waiter_register_ack(&s, ack, 101))
	cancelled, expired := s, s
	testing.expect(t, secure_form_waiter_end_pending(&cancelled, 89999, .Cancelled))
	testing.expect(t, !secure_form_waiter_consume(&cancelled, 89998, 89999))
	testing.expect(t, cancelled.attempt.code == .Cancelled)
	testing.expect(t, !secure_form_waiter_consume(&expired, 89999, 90000))
	testing.expect(t, expired.attempt.code == .Response_Expired)
	testing.expect(t, secure_form_waiter_consume(&s, 89998, 89999))
	testing.expect(t, !secure_form_waiter_end_pending(&s, 89999, .Declined))
	testing.expect(t, !secure_form_waiter_consume(&s, 89999, 89999))
	testing.expect(t, s.receipt == 89998)
}

@(test)
test_secure_form_waiter_retry_without_renewal :: proc(t: ^testing.T) {
	s := secure_form_test_waiter()
	ack := contracts.Secure_Form_Ack{1, "request", "2", "pending", nil}
	testing.expect(t, secure_form_waiter_register_ack(&s, ack, 101))
	testing.expect(t, secure_form_waiter_consume(&s, 102, 103))
	s.attempt = {1, true, .Child_Failed}
	other := s.binding
	other.instance = "different caller"
	testing.expect(t, secure_form_waiter_retry(&s, other, 300_101, 1).code == .Unauthorized)
	first := secure_form_waiter_retry(&s, s.binding, 300_101, 1)
	testing.expect(t, first.action == .Start && first.attempt == 2)
	duplicate := secure_form_waiter_retry(&s, s.binding, 300_102, 1)
	testing.expect(t, duplicate.action == .Join && duplicate.attempt == 2)
	s.attempt = {2, true, .Child_Failed}
	testing.expect(t, secure_form_waiter_retry(&s, s.binding, 300_102, 2).code == .Retention_Expired)
}

@(test)
test_secure_form_waiter_wires_registration_ack :: proc(t: ^testing.T) {
	id :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	s := secure_form_test_waiter()
	s.binding.request_id = id
	payload :: `{"version":1,"request_id":"` + id + `","generation":"2","state":"pending","code":null}`
	prefix :: `{"type":"secure_form_register_ack","protocol_version":1,"payload":`
	valid :: prefix + payload + "}"
	bad := [?]string{
		valid + "{}",
		prefix + payload + `,"extra":0}`,
		`{"type":"secure_form_register_ack","protocol_version":2,"payload":` + payload + "}",
		`{"type":"secure_form_register_ack","type":"secure_form_register_ack","payload":` + payload + "}",
		prefix + `{"version":1,"request_id":"` + id + `","generation":"1","state":"pending","code":null}}`,
		prefix + `{"version":1,"version":1,"request_id":"` + id + `","generation":"2","state":"pending","code":null}}`,
	}
	for raw in bad {
		testing.expect(t, !secure_form_waiter_register_frame(&s, raw, 101))
		testing.expect(t, !s.registered && !s.attempt.terminal)
	}
	testing.expect(t, secure_form_waiter_register_frame(&s, valid, 10_099))
	testing.expect(t, s.registered)
	testing.expect(t, !secure_form_waiter_register_frame(&s, valid, 10_099))
}

@(test)
test_secure_form_waiter_wires_decline_race :: proc(t: ^testing.T) {
	id :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	stem :: `{"type":"secure_form_decline","protocol_version":1,"payload":{"version":1,"request_id":"` + id + `","generation":"`
	frame :: stem + `2"}}`
	s := secure_form_test_waiter()
	s.binding.request_id = id
	_, early := secure_form_waiter_decline_frame(&s, frame, 101)
	testing.expect(t, !early && !s.attempt.terminal)
	reg := contracts.Secure_Form_Ack{1, id, "2", "pending", nil}
	testing.expect(t, secure_form_waiter_register_ack(&s, reg, 101))
	_, stale := secure_form_waiter_decline_frame(&s, stem + `1"}}`, 102)
	testing.expect(t, !stale && !s.attempt.terminal)
	declined, consumed, expired := s, s, s
	ack, ok := secure_form_waiter_decline_frame(&declined, frame, 103)
	testing.expect(t, ok && ack.state == "final" && ack.code == contracts.Secure_Form_Exit.Declined)
	testing.expect(t, !secure_form_waiter_consume(&declined, 102, 104))
	testing.expect(t, secure_form_waiter_consume(&consumed, 102, 103))
	ack, ok = secure_form_waiter_decline_frame(&consumed, frame, 104)
	testing.expect(t, ok && ack.state == "accepted" && ack.code == nil)
	ack, ok = secure_form_waiter_decline_frame(&expired, frame, expired.form_deadline)
	testing.expect(t, ok && ack.state == "final" && ack.code == contracts.Secure_Form_Exit.Response_Expired)
}

@(test)
test_secure_form_directory_rejects_rollback_and_forks :: proc(t: ^testing.T) {
	a :: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	b :: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	c :: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
	first := vault.Verified_Directory{version = 1, head_hash = a, log_hashes = {a}}
	previous, valid := secure_form_directory_advance({}, &first)
	testing.expect(t, valid)
	_, valid = secure_form_directory_advance(previous, &first)
	testing.expect(t, valid)
	newer := vault.Verified_Directory{version = 2, head_hash = b, log_hashes = {a, b}}
	current, extended := secure_form_directory_advance(previous, &newer)
	testing.expect(t, extended && current.sequence == 2)
	_, stale := secure_form_directory_advance(current, &first)
	testing.expect(t, !stale)
	newer.head_hash, newer.log_hashes = c, {a, c}
	_, fork := secure_form_directory_advance(current, &newer)
	testing.expect(t, !fork)
	newer.head_hash, newer.log_hashes = b, {c, b}
	_, broken_prefix := secure_form_directory_advance(previous, &newer)
	testing.expect(t, !broken_prefix)
}

@(test)
test_secure_form_open_attempt_plaintext :: proc(t: ^testing.T) {
	fixture :: #load("../../tests/fixtures/secure-form-v1.json", string)
	f: struct {
		schema, plaintext, recipient_private: string,
		answer: contracts.Secure_Form_Answer,
	}
	if !testing.expect(t, json.unmarshal_string(fixture, &f, .JSON, context.temp_allocator) == nil) do return
	schema, parsed := contracts.secure_form_parse_schema(f.schema)
	if !testing.expect(t, parsed) do return
	scalar, digest: [32]byte
	parsed_hex := vault.hex_decode_into(scalar[:], f.recipient_private) && vault.hex_decode_into(digest[:], f.answer.request_digest)
	if !testing.expect(t, parsed_hex) do return
	secret, valid := secure_form_open_values(scalar[:], digest, f.answer, schema)
	defer secure_form_secret_free(&secret)
	if !testing.expect(t, valid && string(secret.bytes) == f.plaintext) do return

	changed_schema := schema
	changed_schema.fields = schema.fields[:1]
	discarded, invalid := secure_form_open_values(scalar[:], digest, f.answer, changed_schema)
	defer secure_form_secret_free(&discarded)
	testing.expect(t, !invalid && len(discarded.bytes) == 0)

	digest[0] = digest[0] ~ 1
	f.answer.request_digest = vault.hex_encode_lower(digest[:], context.temp_allocator)
	tampered, authentic := secure_form_open_values(scalar[:], digest, f.answer, schema)
	defer secure_form_secret_free(&tampered)
	testing.expect(t, !authentic && len(tampered.bytes) == 0)
}

secure_form_test_gate :: proc(_: rawptr, file: ^os.File, data: []byte) -> (int, contracts.Secure_Form_Exit) {
	when ODIN_OS == .Windows { return 0, .Not_Delivered }
	if len(data) == 0 do return 0, .Success
	n := posix.write(posix.FD(os.fd(file)), raw_data(data), uint(len(data)))
	if n >= 0 do return int(n), .Success
	if posix.errno() == .EINTR || posix.errno() == .EAGAIN do return 0, .Success
	return 0, .Stdin_Failed
}

@(test)
test_secure_form_child_private_stdin_output_and_edited_retry :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows { return }
	tmp, err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	dir := fmt.tprintf("%s/heimdall-secure-form-%d-%d", tmp, os.get_pid(), time.tick_now()._nsec)
	if !testing.expect(t, os.make_directory(dir) == nil) do return
	defer os.remove_all(dir)
	script := fmt.tprintf("%s/run.sh", dir)
	before :: `IFS= read -r data
[[ "$data" == 'synthetic-value' && "$NORMAL_TEST" == 'present' && "$#" == 0 ]] || exit 99
printf 'first stdout'
printf 'first stderr' >&2
exit 7
`
	if !testing.expect(t, os.write_entire_file(script, before) == nil) do return
	input := transmute([]byte)string("synthetic-value\n")
	env := []string{"NORMAL_TEST=present"}
	initial := secure_form_run_child(script, dir, env, input, 5 * time.Second, secure_form_test_gate, nil)
	defer secure_form_child_result_free(&initial)
	testing.expect(t, initial.code == .Child_Failed && initial.exit_code == 7)
	testing.expect_value(t, string(initial.stdout[:]), "first stdout")
	testing.expect_value(t, string(initial.stderr[:]), "first stderr")

	after :: `IFS= read -r data
[[ "$data" == 'synthetic-value' ]] || exit 99
printf 'edited stdout'
`
	if !testing.expect(t, os.write_entire_file(script, after) == nil) do return
	next := secure_form_run_child(script, dir, env, input, 5 * time.Second, secure_form_test_gate, nil)
	defer secure_form_child_result_free(&next)
	testing.expect(t, next.code == .Success && next.exit_code == 0)
	testing.expect_value(t, string(next.stdout[:]), "edited stdout")
	testing.expect(t, len(next.stderr) == 0)
}

@(test)
test_secure_form_fake_hub_wire_and_local_owner_fence :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows { return }
	fds: [2]posix.FD
	if !testing.expect(t, posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds) == .OK) do return
	conn := ws.Connection{connected = true, socket = net.TCP_Socket(fds[0])}
	peer := net.TCP_Socket(fds[1])
	defer net.close(peer)
	defer ws.close(&conn)
	reader := ws.reader_make()
	defer ws.reader_destroy(&reader)
	fixture :: #load("../../tests/fixtures/secure-form-v1.json", string)
	f: struct {
		request: contracts.Secure_Form_Request,
		answer: contracts.Secure_Form_Answer,
		schema, request_signature: string,
	}
	if !testing.expect(t, json.unmarshal_string(fixture, &f, .JSON, context.temp_allocator) == nil) do return
	id := f.request.request_id
	frame, encoded := secure_form_runtime_frame(SECURE_FORM_REGISTER_FRAME, contracts.Secure_Form_Registration{
		1, f.request, f.schema, f.request_signature,
	})
	if !testing.expect(t, encoded) do return
	now := secure_form_now()
	w := Secure_Form_Live{
		waiter = {
			binding = {request_id = id, instance = "inst_fake_secure_form"},
			generation = "13", register_started = now,
			form_deadline = now + 60_000, attempt = {1, false, .Unknown},
		},
		run_count = 7, token = "fake-invocation-proof", last_poll = now, forget = now + 60_000,
		register_wire = strings.clone(frame),
	}
	sync.mutex_lock(&secure_form_live_mu)
	if secure_form_live == nil do secure_form_live = make(map[string]^Secure_Form_Live, runtime.heap_allocator())
	secure_form_live[id] = &w
	sync.mutex_unlock(&secure_form_live_mu)
	defer {
		sync.mutex_lock(&secure_form_live_mu)
		delete_key(&secure_form_live, id)
		sync.mutex_unlock(&secure_form_live_mu)
		delete(w.register_wire)
	}

	secure_form_hub_drain(&conn, 13)
	_, registered, received := ws.read_frame(peer, &reader, time.Second)
	defer delete(registered)
	if !testing.expect(t, received) do return
	payload, unwrapped := secure_form_frame_payload(registered, SECURE_FORM_REGISTER_FRAME, 65_535)
	_, registration_valid := contracts.secure_form_parse_registration(payload)
	testing.expect(t, unwrapped && registration_valid)

	deliver :: proc(peer: net.TCP_Socket, conn: ^ws.Connection, raw: string) -> bool {
		if ws.write_server_text(peer, raw, false) != .Ok do return false
		body, got := ws.poll_text(conn)
		defer delete(body)
		return got && secure_form_hub_receive(conn, 13, body)
	}
	wrong, _ := secure_form_runtime_frame(SECURE_FORM_REGISTER_ACK_FRAME, contracts.Secure_Form_Ack{1,id,"12","pending",nil})
	testing.expect(t, deliver(peer, &conn, wrong))
	testing.expect(t, !w.waiter.registered)
	ack, _ := secure_form_runtime_frame(SECURE_FORM_REGISTER_ACK_FRAME, contracts.Secure_Form_Ack{1,id,"13","pending",nil})
	testing.expect(t, deliver(peer, &conn, ack))
	testing.expect(t, w.waiter.registered)
	decline, _ := secure_form_runtime_frame(SECURE_FORM_DECLINE_FRAME, contracts.Secure_Form_Reference{1,id,"13"})
	testing.expect(t, deliver(peer, &conn, decline))
	_, declined, got := ws.read_frame(peer, &reader, time.Second)
	defer delete(declined)
	ack_payload, ack_unwrapped := secure_form_frame_payload(declined, SECURE_FORM_ACK_FRAME, 1152)
	final_ack, ack_parsed := contracts.secure_form_parse_ack(ack_payload)
	testing.expect(t, got && ack_unwrapped && ack_parsed && final_ack.code == contracts.Secure_Form_Exit.Declined)

	token_ok :: "synthetic-secure-form-owner-test"
	token_other :: "synthetic-secure-form-other-test"
	own_hash := bridge_local_hash_token(token_ok)
	other_hash := bridge_local_hash_token(token_other)
	defer delete(own_hash)
	defer delete(other_hash)
	sync.mutex_lock(&bridge_local_token_mutex)
	if bridge_local_token_records == nil do bridge_local_token_records = make([dynamic]Bridge_Local_Agent_Token_Record, runtime.heap_allocator())
	append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{token_hash = own_hash, role = .Agent,
		agent_instance_id = w.waiter.binding.instance, run_count = w.run_count})
	append(&bridge_local_token_records, Bridge_Local_Agent_Token_Record{token_hash = other_hash, role = .Agent,
		agent_instance_id = "inst_other", run_count = w.run_count})
	sync.mutex_unlock(&bridge_local_token_mutex)
	defer {
		sync.mutex_lock(&bridge_local_token_mutex)
		defer sync.mutex_unlock(&bridge_local_token_mutex)
		for i := len(bridge_local_token_records) - 1; i >= 0; i -= 1 {
			hash := bridge_local_token_records[i].token_hash
			if hash == own_hash || hash == other_hash do unordered_remove(&bridge_local_token_records, i)
		}
	}
	poll_json :: proc(token, id, cap: string, spoof := false) -> string {
		params := make(json.Object, context.temp_allocator)
		params["request_id"] = json.String(id)
		params["poll_token"] = json.String(cap)
		params["attempt"] = json.Integer(1)
		if spoof do params["script"] = json.String("/other/script")
		envelope := struct {v: int, id, token, method: string, params: json.Object}{
			1, "call", token, "agent.secure_form.poll", params,
		}
		bytes, _ := json.marshal(envelope, allocator = context.temp_allocator)
		return string(bytes)
	}
	other := bridge_local_endpoint_handle_jsonl_line(poll_json(token_other, id, w.token))
	defer delete(other)
	testing.expectf(t, strings.contains(other, "\"code\":20") && !strings.contains(other, w.token), "unexpected synthetic wrapper response %s", other)
	own := bridge_local_endpoint_handle_jsonl_line(poll_json(token_ok, id, w.token))
	defer delete(own)
	testing.expectf(t, bridge_local_extract_json_int(own, "code", -1) == 21, "unexpected synthetic wrapper response %s", own)
	spoof := bridge_local_endpoint_handle_jsonl_line(poll_json(token_ok, id, w.token, true))
	defer delete(spoof)
	testing.expect(t, strings.contains(spoof, "\"code\":20"))

	// Reset the isolated waiter to a request whose ACK deadline just passed.
	// Drive the real drain so code 24 triggers the outbound best-effort
	// cancel, then deliver realistic late wire bytes through the same peer.
	w.waiter.attempt = {1, false, .Unknown}
	w.waiter.registered = false
	w.waiter.register_started = secure_form_now() - SECURE_FORM_REGISTER_TIMEOUT_MS
	secure_form_hub_drain(&conn, 13)
	_, cancelled, cancel_received := ws.read_frame(peer, &reader, time.Second)
	defer delete(cancelled)
	cancel_payload, cancel_unwrapped := secure_form_frame_payload(cancelled, SECURE_FORM_CANCEL_FRAME, 1152)
	cancel_ref, cancel_parsed := contracts.secure_form_parse_reference(cancel_payload)
	testing.expect(t, cancel_received && cancel_unwrapped && cancel_parsed && cancel_ref.request_id == id)
	testing.expect(t, w.waiter.attempt.terminal && w.waiter.attempt.code == .Not_Delivered)
	testing.expect(t, deliver(peer, &conn, ack))
	ciphertext, _ := json.marshal(f.answer, allocator = context.temp_allocator)
	late, _ := secure_form_runtime_frame(SECURE_FORM_ANSWER_FRAME, contracts.Secure_Form_Submission{
		1, id, "13", string(ciphertext), "{}",
	})
	testing.expect(t, deliver(peer, &conn, late))
	testing.expect(t, !w.waiter.registered && w.worker == nil && w.raw_submission == "" && !w.waiter.consumed)
	response := bridge_local_endpoint_handle_jsonl_line(poll_json(token_ok, id, w.token))
	defer delete(response)
	testing.expectf(t, bridge_local_extract_json_int(response, "code", -1) == 24, "unexpected synthetic wrapper response %s", response)
}

@(test)
test_secure_form_pinned_device_proof_is_required :: proc(t: ^testing.T) {
	sync.mutex_lock(&bridge_test_config_mutex)
	defer sync.mutex_unlock(&bridge_test_config_mutex)
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	bridge, _ := keystore_test_bridge_ids()
	prev := keystore_test_set_daemon_id(bridge)
	keystore_lock_and_purge(bridge)
	_ = keystore_delete_identity_key(bridge)
	bridge_unseal_forget_identity()
	defer {
		keystore_lock_and_purge(bridge)
		_ = keystore_delete_identity_key(bridge)
		bridge_unseal_forget_identity()
		bridge_config.daemon_id = prev
	}
	if !testing.expect(t, test_provision_identity(bridge)) do return
	if !testing.expect(t, test_store_keyring(bridge, TEST_VAULT_KEY_HEX)) do return
	kr := test_keyring_from_hex(TEST_VAULT_KEY_HEX)
	defer vault.keyring_wipe(&kr)
	chain: struct {
		root_device_id, root_sign_alg, root_sign_pub: string,
		genesis, subject_approval: struct {statement, signature: string},
	}
	if !testing.expect(t, json.unmarshal_string(test_chain_proof(bridge, &kr), &chain, .JSON, context.temp_allocator) == nil) do return
	genesis, gen_ok := vault.statement_parse(chain.genesis.statement)
	approval, approval_ok := vault.statement_parse(chain.subject_approval.statement)
	if !testing.expect(t, gen_ok && approval_ok) do return
	scalar: [32]byte
	if !testing.expect(t, vault.hex_decode_into(scalar[:], TEST_ACCOUNT_ROOT_SCALAR)) do return
	root: ecdsa.Private_Key
	defer ecdsa.private_key_clear(&root)
	if !testing.expect(t, ecdsa.private_key_set_bytes(&root, .SECP256R1, scalar[:])) do return
	approval.epoch_commit = genesis.epoch_commit
	approve_text, canonical := vault.statement_canonical(&approval, context.temp_allocator)
	approve_sig, signed := vault.sign_p256(&root, transmute([]byte)approve_text)
	approve_signature, wrapped := vault.signature_object(&approve_sig, context.temp_allocator)
	if !testing.expect(t, canonical && signed && wrapped) do return
	head := vault.log_entry_hash(approve_text, context.temp_allocator)
	root_pin, pin_ok := vault.root_pin_from_hex(chain.root_device_id, chain.root_sign_alg, chain.root_sign_pub)
	floor := Epoch_Floor{root = root_pin}
	epoch_floor_merge(&floor, bridge, &kr)
	if !testing.expect(t, pin_ok && keystore_store_epoch_floor(bridge, &floor)) do return
	vault_hex: [16]byte
	proof: vault.Directory_Verification_Input = {
		owner = TEST_VAULT_USER_ID, root_device_id = chain.root_device_id, head_hash = head,
		version = 2, current_epoch = 1, pin_seq = 2, pin_hash = head, vault_id = vault.vault_id_hex(kr.vault_id, vault_hex[:]),
		log = {{1, chain.genesis.statement, chain.genesis.signature}, {2, approve_text, approve_signature}},
	}
	device_row :: proc(s: vault.Statement) -> vault.Directory_Device_Item {
		return {s.subject_device_id, s.subject_kind, s.subject_sign_alg, s.subject_wrap_alg,
			s.subject_sign_pub, s.subject_ecdh_pub, true, false}
	}
	proof.devices = {device_row(genesis), device_row(approval)}
	defer {
		sync.mutex_lock(&secure_form_directory_mutex)
		defer sync.mutex_unlock(&secure_form_directory_mutex)
		for key in secure_form_directory_checkpoints {
			if key.owner != TEST_VAULT_USER_ID || key.vault_id != proof.vault_id do continue
			delete_key(&secure_form_directory_checkpoints, key)
			delete(key.owner, runtime.heap_allocator())
			delete(key.vault_id, runtime.heap_allocator())
			break
		}
	}
	proof_bytes, encoded := json.marshal(proof, allocator = context.temp_allocator)
	if !testing.expect(t, encoded == nil) do return
	fixture :: #load("../../tests/fixtures/secure-form-v1.json", string)
	loaded: struct {answer: contracts.Secure_Form_Answer}
	if !testing.expect(t, json.unmarshal_string(fixture, &loaded, .JSON, context.temp_allocator) == nil) do return
	a := loaded.answer
	a.device, a.directory_head, a.directory_sequence = chain.root_device_id, head, "2"
	wire, framed := contracts.secure_form_answer_transcript(a)
	sig, device_signed := vault.sign_p256(&root, wire)
	if !testing.expect(t, framed && device_signed) do return
	a.signature = vault.hex_encode_lower(sig.sig[:], context.temp_allocator)
	digest: [32]byte
	if !testing.expect(t, vault.hex_decode_into(digest[:], a.request_digest)) do return
	testing.expect(t, secure_form_verify_device(TEST_VAULT_USER_ID, bridge, digest, a, string(proof_bytes)))
	testing.expect(t, secure_form_device_fence_live(TEST_VAULT_USER_ID, bridge, a))
	wrong := a
	wrong.directory_sequence = "1"
	testing.expect(t, !secure_form_verify_device(TEST_VAULT_USER_ID, bridge, digest, wrong, string(proof_bytes)))
	wrong = a
	wrong.signature = loaded.answer.signature
	testing.expect(t, !secure_form_verify_device(TEST_VAULT_USER_ID, bridge, digest, wrong, string(proof_bytes)))
	keystore_lock_and_purge(bridge)
	testing.expect(t, !secure_form_verify_device(TEST_VAULT_USER_ID, bridge, digest, a, string(proof_bytes)))
	testing.expect(t, !secure_form_device_fence_live(TEST_VAULT_USER_ID, bridge, a))
}

@(test)
test_secure_form_owner_link_requires_registration_ack :: proc(t: ^testing.T) {
	id :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	hub :: "https://hub.example.test/ninjy/"
	waiter := Secure_Form_Waiter_State{}
	waiter.binding.request_id = id
	testing.expect_value(t, secure_form_owner_link(hub, "https://ui.example.test/", waiter), "")
	waiter.registered = true
	testing.expect_value(t, secure_form_owner_link(hub, "https://ui.example.test/", waiter), "https://ui.example.test/#/secure-forms/" + id)
	testing.expect_value(t, secure_form_owner_link(hub, "", waiter), "https://hub.example.test:443/ninjy/#/secure-forms/" + id)
}
