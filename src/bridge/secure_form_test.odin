package main

import "core:encoding/json"
import "core:fmt"
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
[[ "$data" == 'synthetic-value' && "$NORMAL_TEST" == 'present' ]] || exit 99
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
