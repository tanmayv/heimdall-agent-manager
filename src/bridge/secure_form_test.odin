package main

import "core:testing"
import "odin_test:contracts"

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
