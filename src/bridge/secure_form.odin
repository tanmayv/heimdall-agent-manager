package main

import "core:encoding/json"
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

// Parse the outer envelope without reserializing its payload. The contract
// parser must see the original bytes, including duplicate or malformed keys.
@(private)
secure_form_frame_payload :: proc(raw, action: string, limit: int) -> (string, bool) {
	if len(raw) > limit do return "", false
	t := json.make_tokenizer(raw, .JSON, true)
	first, err := json.get_token(&t)
	if err != nil || first.kind != .Open_Brace do return "", false
	seen_type, seen_version := false, false
	payload := ""
	for i in 0..<3 {
		key, key_err := json.get_token(&t)
		colon, colon_err := json.get_token(&t)
		value, value_err := json.get_token(&t)
		if key_err != nil || key.kind != .String || colon_err != nil || colon.kind != .Colon || value_err != nil do return "", false
		switch key.text {
		case `"type"`:
			if seen_type || value.kind != .String || value.text[1:len(value.text)-1] != action do return "", false
			seen_type = true
		case `"protocol_version"`:
			if seen_version || value.kind != .Integer || value.text != "1" do return "", false
			seen_version = true
		case `"payload"`:
			if payload != "" || value.kind != .Open_Brace do return "", false
			start := int(uintptr(raw_data(value.text)) - uintptr(raw_data(raw)))
			depth := 1
			for depth > 0 {
				token, token_err := json.get_token(&t)
				if token_err != nil do return "", false
				#partial switch token.kind {
				case .Open_Brace, .Open_Bracket: depth += 1
				case .Close_Brace, .Close_Bracket: depth -= 1
				}
				if depth > 8 do return "", false
				if depth == 0 {
					if token.kind != .Close_Brace do return "", false
					end := int(uintptr(raw_data(token.text)) - uintptr(raw_data(raw))) + len(token.text)
					payload = raw[start:end]
				}
			}
		case:
			return "", false
		}
		separator, separator_err := json.get_token(&t)
		expected := i == 2 ? json.Token_Kind.Close_Brace : json.Token_Kind.Comma
		if separator_err != nil || separator.kind != expected do return "", false
	}
	_, eof := json.get_token(&t)
	return payload, eof == .EOF && seen_type && seen_version && payload != ""
}

@(private)
secure_form_waiter_register_frame :: proc(s: ^Secure_Form_Waiter_State, raw: string, now: u64) -> bool {
	payload, ok := secure_form_frame_payload(raw, SECURE_FORM_REGISTER_ACK_FRAME, 1152)
	if !ok do return false
	ack, parsed := contracts.secure_form_parse_ack(payload)
	return parsed && secure_form_waiter_register_ack(s, ack, now)
}
