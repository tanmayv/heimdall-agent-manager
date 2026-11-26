package main

import "odin_test:contracts"

@(private)
SECURE_FORM_REGISTER_FRAME :: "secure_form_register"
@(private)
SECURE_FORM_REGISTER_ACK_FRAME :: "secure_form_register_ack"
@(private)
SECURE_FORM_ANSWER_FRAME :: "secure_form_answer"
@(private)
SECURE_FORM_DECLINE_FRAME :: "secure_form_decline"
@(private)
SECURE_FORM_CANCEL_FRAME :: "secure_form_cancel"
@(private)
SECURE_FORM_ACK_FRAME :: "secure_form_ack"

@(private)
SECURE_FORM_REGISTER_TIMEOUT_MS :: 10_000

// State only, with no secret data. The caller serializes all operations under
// the waiter lock and couples transitions with ownership of key and envelope.
@(private)
Secure_Form_Waiter_State :: struct {
	binding: contracts.Secure_Form_Retry_Binding,
	generation: string,
	registered, consumed, retained: bool,
	register_started, form_deadline, receipt: u64,
	attempt: contracts.Secure_Form_Attempt,
}

@(private)
secure_form_waiter_check_pending :: proc(s: ^Secure_Form_Waiter_State, now: u64) -> bool {
	if s.consumed || s.attempt.terminal do return false
	if now < s.register_started || (!s.registered && now - s.register_started >= SECURE_FORM_REGISTER_TIMEOUT_MS) {
		s.attempt = {1, true, .Not_Delivered}
		return false
	}
	if now >= s.form_deadline {
		s.attempt = {1, true, .Response_Expired}
		return false
	}
	return true
}

@(private)
secure_form_waiter_register_ack :: proc(s: ^Secure_Form_Waiter_State, ack: contracts.Secure_Form_Ack, now: u64) -> bool {
	if ack.request_id != s.binding.request_id || ack.generation != s.generation do return false
	if !secure_form_waiter_check_pending(s, now) || s.registered do return false
	if ack.state == "pending" && ack.code == nil {
		s.registered = true
		return true
	}
	if code, ok := ack.code.?; ack.state == "final" && ok && code == .Unauthorized {
		s.attempt = {1, true, .Unauthorized}
		return true
	}
	return false
}

// Call only after authenticating the envelope and allocating protected storage.
// Receipt is captured at the transport boundary, rather than at this decision.
@(private)
secure_form_waiter_consume :: proc(s: ^Secure_Form_Waiter_State, receipt, now: u64) -> bool {
	if !secure_form_waiter_check_pending(s, now) || !s.registered do return false
	if receipt < s.register_started || now < receipt || now - receipt >= contracts.SECURE_FORM_RETENTION_MS do return false
	s.consumed, s.retained = true, true
	s.receipt = receipt
	s.attempt = {1, false, .Unknown}
	return true
}

@(private)
secure_form_waiter_end_pending :: proc(s: ^Secure_Form_Waiter_State, now: u64, code: contracts.Secure_Form_Exit) -> bool {
	if code != .Cancelled && code != .Declined do return false
	if !secure_form_waiter_check_pending(s, now) do return false
	s.attempt = {1, true, code}
	return true
}

@(private)
secure_form_waiter_retry :: proc(s: ^Secure_Form_Waiter_State, caller: contracts.Secure_Form_Retry_Binding, now, after: u64) -> contracts.Secure_Form_Retry_Decision {
	if s.binding != caller || !s.consumed do return {.Reject, 0, .Unauthorized}
	decision := contracts.secure_form_retry(s.binding, caller, s.receipt, now, after, s.retained, s.attempt)
	if decision.action == .Start {
		s.attempt = {decision.attempt, false, .Unknown}
	}
	return decision
}
