package contracts

import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import vault "odin_test:lib/vault"

SECURE_FORM_VECTORS :: #load("../../tests/fixtures/secure-form-v1.json", string)

@(private = "file")
secure_form_fixture :: proc() -> json.Object {
	value, _ := json.parse_string(SECURE_FORM_VECTORS, .JSON, true, context.temp_allocator)
	return value.(json.Object)
}

@(private = "file")
secure_form_fixture_hex :: proc(s: string) -> []byte {
	raw := make([]byte, len(s) / 2, context.temp_allocator)
	_ = vault.hex_decode_into(raw, s)
	return raw
}

@(private = "file")
secure_form_fixture_request :: proc(f: json.Object) -> Secure_Form_Request {
	o := f["request"].(json.Object)
	return {
		mq_string(o, "owner"), mq_string(o, "bridge"), mq_string(o, "generation"),
		mq_string(o, "instance"), mq_string(o, "task"), mq_string(o, "conversation"),
		mq_string(o, "request_id"), mq_string(o, "deadline"), mq_string(o, "script"), mq_string(o, "schema_digest"),
		mq_string(o, "recipient_key"),
	}
}

@(private = "file")
secure_form_fixture_answer :: proc(f: json.Object) -> Secure_Form_Answer {
	o := f["answer"].(json.Object)
	return {
		mq_string(o, "request_digest"), mq_string(o, "device"), mq_string(o, "directory_sequence"),
		mq_string(o, "directory_head"), mq_string(o, "sender_key"), mq_string(o, "nonce"),
		mq_string(o, "ciphertext"), mq_string(o, "signature"),
	}
}

@(private = "file")
secure_form_fixture_verify :: proc(key, signature: string, transcript: []byte) -> bool {
	pub: ecdsa.Public_Key
	defer ecdsa.public_key_clear(&pub)
	if !ecdsa.public_key_set_bytes(&pub, .SECP256R1, secure_form_fixture_hex(key)) do return false
	sig, ok := secure_form_raw_signature(signature)
	return ok && ecdsa.verify_raw(&pub, .SHA256, transcript, sig[:])
}

@(test)
test_secure_form_display_and_placement :: proc(t: ^testing.T) {
	f := secure_form_fixture()
	r := secure_form_fixture_request(f)
	schema := mq_string(f, "schema")
	testing.expect(t, secure_form_display_matches(r, schema))
	without_logo, _ := strings.replace_all(schema, `"logo":"heimdall",`, "", context.temp_allocator)
	_, no_logo_ok := secure_form_parse_schema(without_logo)
	testing.expect(t, no_logo_ok && !secure_form_display_matches(r, without_logo))
	registration := Secure_Form_Registration{1, r, schema, mq_string(f, "request_signature")}
	raw_registration, reg_err := json.marshal(registration, allocator = context.temp_allocator)
	_, registration_ok := secure_form_parse_registration(string(raw_registration))
	testing.expect(t, reg_err == nil && registration_ok)
	registration.schema = without_logo
	bad_bytes, _ := json.marshal(registration, allocator = context.temp_allocator)
	_, substituted := secure_form_parse_registration(string(bad_bytes))
	testing.expect(t, !substituted)

	for invalid in ([]string{"login.sh", "/", "/scripts/", "/scripts//login.sh", "/scripts/../login.sh", "/scripts/./login.sh"}) {
		changed := r
		changed.script = invalid
		_, valid := secure_form_request_transcript(changed)
		testing.expect(t, !valid, invalid)
	}
	for obsolete in ([]string{`"entry":{}`, `"destination":"https://example.test"`, `"manifest_digest":"00"`}) {
		deprecated := strings.concatenate({"{", obsolete, ",", string(raw_registration[1:])}, context.temp_allocator)
		_, valid := secure_form_parse_registration(deprecated)
		testing.expect(t, !valid, obsolete)
	}

	msg, ok := secure_form_request_transcript(r)
	testing.expect(t, ok && string(msg) == string(secure_form_fixture_hex(mq_string(f, "request_transcript"))))
	testing.expect(t, secure_form_fixture_verify(mq_string(f, "bridge_public"), mq_string(f, "request_signature"), msg))
	testing.expect(t, secure_form_admit_initial(r, r, 1700000179999, .Pending))
	testing.expect(t, !secure_form_admit_initial(r, r, 1700000180000, .Pending))
	testing.expect(t, !secure_form_admit_initial(r, r, 1700000179999, .Forwarding))
	testing.expect(t, secure_form_hub_transition(.Forwarding, .Accepted))
	testing.expect(t, !secure_form_hub_transition(.Final, .Forwarding))
	testing.expect(t, secure_form_bridge_transition(.Pending, .Consumed))
	testing.expect(t, !secure_form_bridge_transition(.Final, .Running))
	make_ack := proc(id, state, code: string) -> string {
		return strings.concatenate({`{"version":1,"request_id":"`, id, `","generation":"13","state":"`,
			state, `","code":`, code, "}"}, context.temp_allocator)
	}
	final_ack, final_ok := secure_form_parse_ack(make_ack(r.request_id, "final", "29"))
	testing.expect(t, final_ok && final_ack.code == Secure_Form_Exit.Retention_Expired)
	_, nonfinal_ok := secure_form_parse_ack(make_ack(r.request_id, "accepted", "29"))
	testing.expect(t, !nonfinal_ok)
	_, accepted_ok := secure_form_parse_ack(make_ack(r.request_id, "accepted", "null"))
	testing.expect(t, accepted_ok)
	_, unknown_code_ok := secure_form_parse_ack(make_ack(r.request_id, "final", "127"))
	testing.expect(t, !unknown_code_ok)

	for i in 0..<6 {
		substitution := r
		switch i {
		case 0: substitution.owner = "other"
		case 1: substitution.bridge = "other"
		case 2: substitution.instance = "other"
		case 3: substitution.generation = "12"
		case 4: substitution.request_id = strings.repeat("01", 32, context.temp_allocator)
		case 5: substitution.script = "/other/login.sh"
		}
		testing.expect(t, !secure_form_admit_initial(substitution, r, 1700000179999, .Pending))
		other_msg, other_ok := secure_form_request_transcript(substitution)
		testing.expect(t, other_ok && !secure_form_fixture_verify(mq_string(f, "bridge_public"), mq_string(f, "request_signature"), other_msg))
	}
	r.request_id = "ab"
	_, short_id := secure_form_request_transcript(r)
	testing.expect(t, !short_id)
}

@(test)
test_secure_form_rejects_malformed_schema_and_answers :: proc(t: ^testing.T) {
	f := secure_form_fixture()
	raw := mq_string(f, "schema")
	schema, ok := secure_form_parse_schema(raw)
	if !testing.expect(t, ok) do return
	_, values := secure_form_parse_values(mq_string(f, "plaintext"), schema, context.temp_allocator)
	testing.expect(t, values)
	for bad in ([]string{
		`{"version":1,"purpose":"Use.","purpose":"Other.","fields":[{"id":"a","label":"A","type":"text"}]}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"A","type":"text"},{"id":"a","label":"B","type":"text"}]}`,
		`{"version":1,"purpose":"Use.","logo":"https://example.test/a.svg","fields":[{"id":"a","label":"A","type":"text"}]}`,
		`{"version":1,"purpose":"Use.\nOther.","fields":[{"id":"a","label":"A","type":"text"}]}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"A","type":"text","default":"x"}]}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"A","type":"text"}],"":null}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"A","type":"text"},]}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"\ud800","type":"text"}]}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"\uzzzz","type":"text"}]}`,
		`{"version":1,"purpose":"Use.","fields":[{"id":"a","label":"A","type":"text"}],"\u0076ersion":1}`,

		strings.concatenate({raw, " {}"}, context.temp_allocator),
	}) {
		_, accepted := secure_form_parse_schema(bad)
		testing.expect(t, !accepted, bad)
	}
	for bad in ([]string{
		`{"login":"x","login":"y","pass":"x","environment":"test","roles":["observer"]}`,
		`{"login":"x","pass":"","environment":"test","roles":["observer"]}`,
		`{"login":"x","pass":"x","environment":"prod","roles":["observer"]}`,
		`{"login":"x","pass":"x","environment":"test","roles":["observer","observer"]}`,
		`{"login":"x","pass":"x","environment":"test","roles":["unknown"]}`,
	}) {
		_, accepted := secure_form_parse_values(bad, schema, context.temp_allocator)
		testing.expect(t, !accepted, bad)
	}
}

@(test)
test_secure_form_answer_trust_and_crypto :: proc(t: ^testing.T) {
	f := secure_form_fixture()
	e := secure_form_fixture_answer(f)
	r_msg, r_ok := secure_form_request_transcript(secure_form_fixture_request(f))
	if !testing.expect(t, r_ok) do return
	digest := secure_form_digest(r_msg)
	msg, msg_ok := secure_form_answer_transcript(e)
	testing.expect(t, msg_ok && string(msg) == string(secure_form_fixture_hex(mq_string(f, "answer_transcript"))))
	pub := mq_string(f, "device_public")
	testing.expect(t, secure_form_fixture_verify(pub, e.signature, msg))
	_, der_ok := secure_form_raw_signature("3044")
	testing.expect(t, !der_ok)
	_, zero_ok := secure_form_raw_signature(strings.repeat("00", 64, context.temp_allocator))
	testing.expect(t, !zero_ok)
	head: [32]byte
	_ = vault.hex_decode_into(head[:], e.directory_head)
	testing.expect(t, secure_form_directory_matches(e, digest, 42, head))
	testing.expect(t, !secure_form_directory_matches(e, digest, 43, head))
	head[0] ~= 1
	testing.expect(t, !secure_form_directory_matches(e, digest, 42, head))
	older := e
	older.directory_sequence = "41"
	older_msg, older_ok := secure_form_answer_transcript(older)
	testing.expect(t, older_ok && !secure_form_fixture_verify(pub, older.signature, older_msg))
	bad_nonce := e
	bad_nonce.nonce = "00"
	_, nonce_ok := secure_form_answer_transcript(bad_nonce)
	testing.expect(t, !nonce_ok)

	encoded, enc_err := json.marshal(e, allocator = context.temp_allocator)
	request := secure_form_fixture_request(f)
	submission := Secure_Form_Submission{1, request.request_id, request.generation, string(encoded), "{}"}
	wire, wire_err := json.marshal(submission, allocator = context.temp_allocator)
	_, accepted := secure_form_parse_submission(string(wire))
	testing.expect(t, enc_err == nil && wire_err == nil && accepted)
	submission.directory_proof = strings.repeat("x", SECURE_FORM_PROOF_MAX + 1, context.temp_allocator)
	oversize, _ := json.marshal(submission, allocator = context.temp_allocator)
	_, oversized := secure_form_parse_submission(string(oversize))
	testing.expect(t, !oversized)

	priv: ecdh.Private_Key
	sender: ecdh.Public_Key
	defer ecdh.private_key_clear(&priv)
	defer ecdh.public_key_clear(&sender)
	if !testing.expect(t, ecdh.private_key_set_bytes(&priv, .SECP256R1, secure_form_fixture_hex(mq_string(f, "recipient_private")))) do return
	if !testing.expect(t, ecdh.public_key_set_bytes(&sender, .SECP256R1, secure_form_fixture_hex(e.sender_key))) do return
	shared, key: [32]byte
	if !testing.expect(t, ecdh.ecdh(&priv, &sender, shared[:])) do return
	testing.expect(t, string(shared[:]) == string(secure_form_fixture_hex(mq_string(f, "shared"))))
	hkdf.extract_and_expand(.SHA256, digest[:], shared[:], transmute([]byte)string(SECURE_FORM_ANSWER), key[:])
	testing.expect(t, string(key[:]) == string(secure_form_fixture_hex(mq_string(f, "key"))))
	plaintext := transmute([]byte)mq_string(f, "plaintext")
	ct := make([]byte, len(plaintext) + 16, context.temp_allocator)
	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ct[:len(plaintext)], ct[len(plaintext):], secure_form_fixture_hex(e.nonce), digest[:], plaintext)
	testing.expect_value(t, base64.encode(ct, allocator = context.temp_allocator), e.ciphertext)

	negatives := f["negative"].(json.Array)
	for item in negatives {
		negative := item.(json.Object)
		name, value := mq_string(negative, "name"), mq_string(negative, "value")
		expected := secure_form_fixture_hex(mq_string(negative, "transcript"))
		switch name {
		case "stale_generation", "cross_owner":
			live := secure_form_fixture_request(f)
			changed := live
			if name == "stale_generation" do changed.generation = value
			if name == "cross_owner" do changed.owner = value
			wire, ok := secure_form_request_transcript(changed)
			testing.expect(t, ok && string(wire) == string(expected), name)
			testing.expect(t, !secure_form_admit_initial(changed, live, 1700000179999, .Pending), name)
			testing.expect(t, !secure_form_fixture_verify(mq_string(f, "bridge_public"), mq_string(f, "request_signature"), wire), name)
		case "stale_directory":
			changed := e
			changed.directory_sequence = value
			wire, ok := secure_form_answer_transcript(changed)
			testing.expect(t, ok && string(wire) == string(expected), name)
			testing.expect(t, !secure_form_fixture_verify(pub, e.signature, wire), name)
		case "der_signature":
			testing.expect(t, !secure_form_fixture_verify(pub, value, msg), name)
		case "wrong_aad":
			buffer := make([]byte, len(plaintext), context.temp_allocator)
			nonce := secure_form_fixture_hex(e.nonce)
			body, tag := ct[:len(plaintext)], ct[len(plaintext):]
			testing.expect(t, aes.open_gcm(&gcm, buffer, nonce, digest[:], body, tag))
			testing.expect(t, !aes.open_gcm(&gcm, buffer, nonce, secure_form_fixture_hex(value), body, tag), name)
		case:
			testing.expect(t, false, name)
		}
	}
}

@(test)
test_secure_form_retry_binding_and_expiry :: proc(t: ^testing.T) {
	f := secure_form_fixture()
	r := secure_form_fixture_request(f)
	binding := proc(req: Secure_Form_Request) -> Secure_Form_Retry_Binding {
		return {req.request_id, req.schema_digest, req.script, req.owner, req.bridge, req.instance, req.task}
	}
	b := binding(r)
	// Script bytes are intentionally absent from the retry identity.
	edited := binding(secure_form_fixture_request(f))
	testing.expect(t, b == edited)

	retry_bytes, _ := json.marshal(Secure_Form_Retry_Command{1, r.request_id, "1"}, allocator = context.temp_allocator)
	_, retry_ok := secure_form_parse_retry(string(retry_bytes))
	testing.expect(t, retry_ok)
	stale_bytes, _ := json.marshal(Secure_Form_Retry_Command{1, r.request_id, "01"}, allocator = context.temp_allocator)
	_, noncanonical := secure_form_parse_retry(string(stale_bytes))
	testing.expect(t, !noncanonical)

	failed := Secure_Form_Attempt{1, true, .Child_Failed}
	decision := secure_form_retry(b, edited, 100, 300099, 1, true, failed)
	testing.expect(t, decision.action == .Start && decision.attempt == 2)
	replay := secure_form_retry(b, b, 100, 300099, 1, true, {2, false, .Unknown})
	testing.expect(t, replay.action == .Join && replay.attempt == 2)
	expired_replay := secure_form_retry(b, edited, 100, 300100, 1, false, {2, false, .Unknown})
	testing.expect(t, expired_replay.action == .Join && expired_replay.attempt == 2 && expired_replay.code == .Unknown)
	discarded_replay := secure_form_retry(b, edited, 100, 101, 1, false, {2, true, .Success})
	testing.expect(t, discarded_replay.action == .Join && discarded_replay.attempt == 2 && discarded_replay.code == .Success)
	uncertain := secure_form_retry(b, edited, 100, 300099, 1, true, {1, true, .Unknown})
	testing.expect(t, uncertain.action == .Start && uncertain.attempt == 2)

	unknown := secure_form_retry(b, b, 100, 300099, 2, true, {2, false, .Unknown})
	testing.expect(t, unknown.action == .Reject && unknown.code == .Unknown)
	expired := secure_form_retry(b, b, 100, 300100, 1, true, failed)
	testing.expect(t, expired.action == .Reject && int(expired.code) == 29)
	discarded := secure_form_retry(b, b, 100, 101, 1, false, failed)
	testing.expect(t, discarded.action == .Reject && discarded.code == .Retention_Expired)
	changed := b
	changed.script = "/other/login.sh"
	testing.expect(t, secure_form_retry(b, changed, 100, 101, 1, true, failed).code == .Unauthorized)
	changed = b
	changed.schema_digest = strings.repeat("00", 32, context.temp_allocator)
	testing.expect(t, secure_form_retry(b, changed, 100, 101, 1, true, failed).code == .Unauthorized)
	changed = b
	changed.task = "other_task"
	untrusted_join := secure_form_retry(b, changed, 100, 300100, 1, false, {2, true, .Success})
	testing.expect(t, untrusted_join.action == .Reject && untrusted_join.code == .Unauthorized)
	testing.expect(t, secure_form_retry(b, changed, 100, 101, 1, true, failed).code == .Unauthorized)
}
