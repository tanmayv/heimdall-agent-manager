package taskchain

import domain "odin_test:hub/domain"

// Auto-nudge decision logic. The *scheduling* (timer loop, wake/launch, wrapper
// push) lives on the Bridge to keep the Hub lean, but the decision math is pure
// and shared/testable here so both sides agree on thresholds, cooldown, and
// target selection. It mirrors the ham-daemon nudge scheduler
// (task_nudge_scheduler.odin) semantics.

// Nudge_Config carries the per-status staleness thresholds and cooldown, ported
// from the daemon nudge_* config keys. All values are seconds.
Nudge_Config :: struct {
	enabled:                    bool,
	ready_after_seconds:        int, // Assigned/queued waiting to start
	review_after_seconds:       int, // In_Validation waiting on reviewer
	working_stale_after_seconds: int, // In_Progress with no movement
	need_improvements_after_seconds: int, // Validated_Not_Good back to assignee
	cooldown_seconds:           int, // min gap between nudges for same target
}

// default_nudge_config mirrors the daemon defaults (disabled by default).
default_nudge_config :: proc() -> Nudge_Config {
	return Nudge_Config{
		enabled                         = false,
		ready_after_seconds             = 300,
		review_after_seconds            = 300,
		working_stale_after_seconds     = 900,
		need_improvements_after_seconds = 300,
		cooldown_seconds                = 300,
	}
}

// nudge_threshold_seconds returns the staleness threshold for a status, or 0 if
// the status is not eligible for scheduled nudging.
nudge_threshold_seconds :: proc(cfg: Nudge_Config, status: domain.Task_Status) -> int {
	#partial switch status {
	case .Assigned:
		return cfg.ready_after_seconds
	case .In_Progress:
		return cfg.working_stale_after_seconds
	case .In_Validation:
		return cfg.review_after_seconds
	case .Validated_Not_Good:
		return cfg.need_improvements_after_seconds
	case:
		return 0
	}
}

// Nudge_Decision is the pure output of evaluating one task at a point in time.
Nudge_Decision :: struct {
	should_nudge: bool,
	target:       Nudge_Target,
	reason:       string, // "" when should_nudge, else why it was skipped
}

// evaluate_nudge decides whether a task should be nudged now. Inputs are all
// caller-supplied so this is deterministic and clock-injectable:
//   - status:          current task status
//   - updated_at_ms:   task.updated_at as unix ms (last movement)
//   - last_nudge_ms:   last nudge time for the resolved target (0 = never)
//   - now_ms:          current time in unix ms
// The caller resolves the concrete target instance separately; here we only
// classify the target role and gate on threshold + cooldown.
evaluate_nudge :: proc(cfg: Nudge_Config, status: domain.Task_Status, updated_at_ms, last_nudge_ms, now_ms: i64) -> Nudge_Decision {
	if !cfg.enabled do return Nudge_Decision{should_nudge = false, reason = "disabled"}

	// Terminal / non-actionable states never nudge.
	target := nudge_target_for_status(status)
	if target == .None do return Nudge_Decision{should_nudge = false, target = .None, reason = "no_target"}

	threshold := nudge_threshold_seconds(cfg, status)
	if threshold <= 0 do return Nudge_Decision{should_nudge = false, target = target, reason = "no_threshold"}

	if updated_at_ms <= 0 do return Nudge_Decision{should_nudge = false, target = target, reason = "no_updated_at"}
	if now_ms - updated_at_ms < i64(threshold) * 1000 {
		return Nudge_Decision{should_nudge = false, target = target, reason = "not_stale"}
	}

	cooldown := cfg.cooldown_seconds
	if cooldown <= 0 do cooldown = 300
	if last_nudge_ms > 0 && now_ms - last_nudge_ms < i64(cooldown) * 1000 {
		return Nudge_Decision{should_nudge = false, target = target, reason = "cooldown"}
	}

	return Nudge_Decision{should_nudge = true, target = target, reason = ""}
}
