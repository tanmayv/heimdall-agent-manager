package dbtelemetry

import "core:sync"

// Opt-in lock-wait profile (Scale H load harness, docs/guides/scale-harness.md).
//
// The hub's two hot locks decide between the remaining scaling options: the
// process-wide unit-of-work mutex (sqlite tx_mutex, the single SQLite writer)
// and the in-process state mutexes (taskv2 Service.state_mutex and the bridge
// runtime connection state_mutex). Basic telemetry already times tx_mutex for
// Prometheus, but it never covers the state mutexes and its histograms cannot
// be read back as plain totals. This profile accumulates, per lock, the number
// of acquisitions, the summed and maximum wait, the number of acquisitions that
// waited (>= PROFILE_CONTENDED_NS) and, where the call site can carry the
// acquire time, the summed hold.
//
// It is OFF by default and independent of HEIMDALL_DB_TELEMETRY: only the load
// harness calls set_lock_profile(true). Off, profile_start is one relaxed
// atomic load and a branch, and every other proc returns at once on its zero
// argument; nothing is registered or allocated.

Profile_Lock :: enum u8 {
	Uow_Tx,        // sqlite tx_mutex (outer unit of work)
	Taskv2_State,  // taskv2 Service.state_mutex
	Taskv2_Timers, // taskv2 Timer_Service.mutex (the in-memory timer heap)
	Runtime_State, // project Bridge_Runtime_Connection.state_mutex
}

PROFILE_LOCK_LABELS := [Profile_Lock]string {
	.Uow_Tx        = "tx_mutex",
	.Taskv2_State  = "taskv2_state_mutex",
	.Taskv2_Timers = "taskv2_timers_mutex",
	.Runtime_State = "runtime_state_mutex",
}

// An acquisition that waited at least this long counts as contended. An
// uncontended mutex_lock plus two clock reads stays well under it.
PROFILE_CONTENDED_NS :: 2_000

Lock_Profile :: struct {
	acquisitions: i64,
	contended:    i64,
	wait_ns:      i64,
	max_wait_ns:  i64,
	hold_ns:      i64,
	holds:        i64, // acquisitions whose hold was measured
}

@(private)
profile_on: bool
@(private)
profile_acc: [Profile_Lock]Lock_Profile

// set_lock_profile turns the profile on or off. Harness/test use; the hub
// never calls it.
set_lock_profile :: proc "contextless" (on: bool) {
	sync.atomic_store_explicit(&profile_on, on, .Relaxed)
}

lock_profile_enabled :: #force_inline proc "contextless" () -> bool {
	return sync.atomic_load_explicit(&profile_on, .Relaxed)
}

lock_profile_reset :: proc "contextless" () {
	for l in Profile_Lock {
		a := &profile_acc[l]
		sync.atomic_store(&a.acquisitions, 0)
		sync.atomic_store(&a.contended, 0)
		sync.atomic_store(&a.wait_ns, 0)
		sync.atomic_store(&a.max_wait_ns, 0)
		sync.atomic_store(&a.hold_ns, 0)
		sync.atomic_store(&a.holds, 0)
	}
}

lock_profile_snapshot :: proc "contextless" () -> (out: [Profile_Lock]Lock_Profile) {
	for l in Profile_Lock {
		a := &profile_acc[l]
		out[l] = Lock_Profile{
			acquisitions = sync.atomic_load(&a.acquisitions),
			contended    = sync.atomic_load(&a.contended),
			wait_ns      = sync.atomic_load(&a.wait_ns),
			max_wait_ns  = sync.atomic_load(&a.max_wait_ns),
			hold_ns      = sync.atomic_load(&a.hold_ns),
			holds        = sync.atomic_load(&a.holds),
		}
	}
	return
}

// profile_start returns the clock before an acquisition, or 0 when the profile
// is off (the only cost on the default path).
profile_start :: #force_inline proc "contextless" () -> i64 {
	if !lock_profile_enabled() do return 0
	return now_ns()
}

// profile_acquired records one acquisition that started at t0 (from
// profile_start) and returns the acquire time for profile_released, or 0 when
// t0 is 0.
profile_acquired :: proc "contextless" (l: Profile_Lock, t0: i64) -> i64 {
	if t0 == 0 do return 0
	t1 := now_ns()
	wait := t1 - t0
	if wait < 0 do wait = 0
	a := &profile_acc[l]
	sync.atomic_add(&a.acquisitions, 1)
	sync.atomic_add(&a.wait_ns, wait)
	if wait >= PROFILE_CONTENDED_NS do sync.atomic_add(&a.contended, 1)
	for {
		cur := sync.atomic_load(&a.max_wait_ns)
		if wait <= cur do break
		if _, swapped := sync.atomic_compare_exchange_weak(&a.max_wait_ns, cur, wait); swapped do break
	}
	return t1
}

// profile_released records the hold of an acquisition profile_acquired timed
// (acquired != 0).
profile_released :: proc "contextless" (l: Profile_Lock, acquired: i64) {
	if acquired == 0 do return
	held := now_ns() - acquired
	if held < 0 do held = 0
	a := &profile_acc[l]
	sync.atomic_add(&a.hold_ns, held)
	sync.atomic_add(&a.holds, 1)
}

// profiled_mutex_lock is sync.mutex_lock plus the profile's wait accounting.
// Returns the acquire time for profiled_mutex_unlock (0 when off).
profiled_mutex_lock :: #force_inline proc "contextless" (mu: ^sync.Mutex, l: Profile_Lock) -> i64 {
	if !lock_profile_enabled() {
		sync.mutex_lock(mu)
		return 0
	}
	t0 := now_ns()
	sync.mutex_lock(mu)
	return profile_acquired(l, t0)
}

profiled_mutex_unlock :: #force_inline proc "contextless" (mu: ^sync.Mutex, l: Profile_Lock, acquired: i64) {
	if acquired != 0 do profile_released(l, acquired)
	sync.mutex_unlock(mu)
}
