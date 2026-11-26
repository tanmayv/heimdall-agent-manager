package contracts

import "core:encoding/json"

SECURE_FORM_REGISTER_FRAME :: "secure_form_register"
SECURE_FORM_REGISTER_ACK_FRAME :: "secure_form_register_ack"
SECURE_FORM_ANSWER_FRAME :: "secure_form_answer"
SECURE_FORM_DECLINE_FRAME :: "secure_form_decline"
SECURE_FORM_CANCEL_FRAME :: "secure_form_cancel"
SECURE_FORM_ACK_FRAME :: "secure_form_ack"
SECURE_FORM_CHANGED_EVENT :: "secure_form.changed"
SECURE_FORM_API_PATH :: "/api/v1/secure-forms"

SECURE_FORM_WAIT_MIN_SECONDS :: 10
SECURE_FORM_WAIT_DEFAULT_SECONDS :: 180
SECURE_FORM_WAIT_MAX_SECONDS :: 600
SECURE_FORM_EXECUTION_MIN_SECONDS :: 1
SECURE_FORM_EXECUTION_DEFAULT_SECONDS :: 60
SECURE_FORM_EXECUTION_MAX_SECONDS :: 600

Secure_Form_Wire_Frame :: struct($Payload: typeid) {
	type: string,
	protocol_version: int,
	payload: Payload,
}

secure_form_wire_payload :: proc(raw, expected: string, limit: int, allocator := context.temp_allocator) -> (string, bool) {
	o, ok := secure_form_object(raw, limit, allocator)
	if !ok || len(o) != 3 do return "", false
	kind, _ := o["type"].(json.String)
	version, _ := o["protocol_version"].(json.Integer)
	payload, found := o["payload"].(json.Object)
	if string(kind) != expected || version != 1 || !found do return "", false
	out, err := json.marshal(payload, allocator = allocator)
	return string(out), err == nil
}
