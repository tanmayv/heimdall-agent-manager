package delivery

import "core:strconv"
import "core:strings"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import jsonx "odin_test:lib/jsonx"

on_command_result :: proc(s: ^Service, bridge_id, command_id, result_json: string) {
	colon := strings.last_index(command_id, ":")
	if colon <= 0 || !strings.has_prefix(command_id, contracts.DELIVERY_ID_PREFIX) do return
	id := command_id[:colon]
	attempt, parsed := strconv.parse_int(command_id[colon + 1:])
	if !parsed || attempt < 1 do return
	status := jsonx.extract_string(result_json, "status", top_level_only = false)
	defer delete(status)
	if status != "accepted" && status != "succeeded" && status != "failed" do return
	uow, ok, _ := iface.unit_of_work_begin(s.factory)
	if !ok do return
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	repo := &uow.repos.pipeline_deliveries
	d, found, err := repo.get(repo.ctx, id)
	if !found || err.code != .None do return
	defer domain.pipeline_delivery_destroy(&d)
	if d.bridge_id != bridge_id || d.state != domain.DELIVERY_FORWARDED do return
	if status == "accepted" {
		iface.unit_of_work_rollback(&uow); uow.ctx = nil
		if attempt == d.attempt do enqueue_answer(s, bridge_id, .In_Progress, d.ack_reply)
		return
	}
	op := Answer_Op.Ack
	delay := i64(0)
	changed := false
	finalized := false
	if status == "succeeded" {
		raw_outcome := jsonx.extract_string(result_json, "outcome", top_level_only = false)
		defer delete(raw_outcome)
		outcome := raw_outcome
		if outcome == "" do outcome = contracts.DELIVERY_OUTCOME_NOTIFIED
		if d.kind == domain.DELIVERY_KIND_PROMPT && d.message_id != "" {
			changed, finalized, err = prompt_succeeded(s, &uow, d)
		} else {
			changed, err = close_delivery(s, &uow, d, domain.DELIVERY_DONE, "", outcome)
			finalized = changed
		}
		if err.code != .None do return
	} else {
		if attempt != d.attempt do return
		class := jsonx.extract_string(result_json, "class", top_level_only = false)
		defer delete(class)
		// wire_error_parse expects a top-level error; command_result nests it.
		raw_error, _ := jsonx.extract_raw_object(result_json, "error", top_level_only = false)
		defer delete(raw_error)
		error_frame := strings.concatenate({"{\"error\":", raw_error, "}"})
		defer delete(error_frame)
		wire_error, _ := contracts.wire_error_parse(error_frame)
		defer {delete(wire_error.cause); delete(wire_error.message); delete(wire_error.scope)}
		reason := wire_error.cause
		if class == contracts.DELIVERY_CLASS_RETRY && d.attempt < s.max_deliver {
			delay = retry_delay_ms(d.attempt, i64(jsonx.extract_int(result_json, "retry_after_ms")))
			next := d
			next.reason = reason; next.updated_at = platform.clock_now(s.clock)
			ms, _ := platform.rfc3339_to_unix_ms(next.updated_at)
			next.retry_at = platform.format_rfc3339_utc(time.Time{_nsec = (ms + delay) * 1_000_000})
			changed, err = repo.transition(repo.ctx, next, d.state)
			if err.code != .None do return
			op = .Nak_Delay
		} else {
			op = .Term
			if class ==
			   contracts.DELIVERY_CLASS_RETRY {reason = "no_answer"} else if reason == "" {reason = "start_failed"}
			if class != contracts.DELIVERY_CLASS_RETRY {
				changed, err = try_replace(s, &uow, d, .Fatal_Answer)
				if err.code != .None do return
			}
			if !changed {
				changed, err = close_delivery(s, &uow, d, domain.DELIVERY_FAILED, reason, "")
				if err.code != .None do return
				finalized = changed
			}
		}
	}
	committed, _ := iface.unit_of_work_commit(&uow); uow.ctx = nil
	if committed && changed {
		enqueue_answer(s, bridge_id, op, d.ack_reply, delay)
		if finalized do prune_after_final(s)
	}
}
