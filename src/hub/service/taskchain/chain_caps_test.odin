package taskchain

// SCHED-1b: chain cap validation (REQ-SCHED-34, spec decision 3):
// max_parallel 0 removes the cap, otherwise M >= 2 and 1 <= r <= M - 1,
// review_reserve defaulting to 1.

import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_chain_caps_validation :: proc(t: ^testing.T) {
	Case :: struct {
		name:                  string,
		m0, r0:                int,
		input:                 Update_Chain_Input,
		ok:                    bool,
		m, r:                  int,
		changed:               bool,
	}
	cases := []Case{
		{"absent keys change nothing", 3, 1, {}, true, 3, 1, false},
		{"set M defaults r to 1", 0, 0, {max_parallel = 3, has_max_parallel = true}, true, 3, 1, true},
		{"set M and r", 0, 0, {max_parallel = 4, has_max_parallel = true, review_reserve = 2, has_review_reserve = true}, true, 4, 2, true},
		{"M = 1 refused", 0, 0, {max_parallel = 1, has_max_parallel = true}, false, 0, 0, false},
		{"negative M refused", 0, 0, {max_parallel = -1, has_max_parallel = true}, false, 0, 0, false},
		{"r = 0 refused", 3, 1, {review_reserve = 0, has_review_reserve = true}, false, 3, 1, false},
		{"r = M refused", 3, 1, {review_reserve = 3, has_review_reserve = true}, false, 3, 1, false},
		{"r alone within M", 4, 1, {review_reserve = 3, has_review_reserve = true}, true, 4, 3, true},
		{"lowering M clamps a stored r", 5, 4, {max_parallel = 3, has_max_parallel = true}, true, 3, 2, true},
		{"M = 0 removes cap and reserve", 3, 1, {max_parallel = 0, has_max_parallel = true}, true, 0, 0, true},
		{"r without a cap refused", 0, 0, {review_reserve = 1, has_review_reserve = true}, false, 0, 0, false},
		{"same values unchanged", 3, 1, {max_parallel = 3, has_max_parallel = true, review_reserve = 1, has_review_reserve = true}, true, 3, 1, false},
	}
	for c in cases {
		chain := domain.Task_Chain{max_parallel = c.m0, review_reserve = c.r0}
		changed, err := apply_chain_caps(&chain, c.input)
		testing.expectf(t, (err.code == .None) == c.ok, "%s: ok=%v (err %q)", c.name, c.ok, err.message)
		if !c.ok {
			testing.expectf(t, err.code == .Validation_Failed, "%s: validation error", c.name)
			continue
		}
		testing.expectf(t, chain.max_parallel == c.m && chain.review_reserve == c.r, "%s: M=%d r=%d (got %d, %d)", c.name, c.m, c.r, chain.max_parallel, chain.review_reserve)
		testing.expectf(t, changed == c.changed, "%s: changed=%v", c.name, c.changed)
	}
}
