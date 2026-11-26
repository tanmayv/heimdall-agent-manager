package dbtelemetry

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// The profile is process-global, so both checks run in one test (the runner
// runs tests of a package on parallel threads).
@(test)
test_lock_profile :: proc(t: ^testing.T) {
	lock_profile_off_records_nothing(t)
	lock_profile_on_counts_waits_and_holds(t)
}

// Off (the default) the profile records nothing and returns no acquire time.
lock_profile_off_records_nothing :: proc(t: ^testing.T) {
	set_lock_profile(false)
	lock_profile_reset()
	mu: sync.Mutex
	h := profiled_mutex_lock(&mu, .Taskv2_State)
	testing.expect_value(t, h, i64(0))
	profiled_mutex_unlock(&mu, .Taskv2_State, h)
	testing.expect_value(t, profile_start(), i64(0))
	testing.expect_value(t, profile_acquired(.Uow_Tx, 0), i64(0))
	snap := lock_profile_snapshot()
	for l in Profile_Lock do testing.expect_value(t, snap[l], Lock_Profile{})
	testing.expect(t, sync.mutex_try_lock(&mu), "mutex released")
	sync.mutex_unlock(&mu)
}

// On, every acquisition is counted with its hold, and a waiter blocked behind a
// holder is counted as contended with a wait of at least the hold.
lock_profile_on_counts_waits_and_holds :: proc(t: ^testing.T) {
	set_lock_profile(true)
	defer set_lock_profile(false)
	lock_profile_reset()
	defer lock_profile_reset()
	Shared :: struct { mu: sync.Mutex, held: sync.Sema }
	shared: Shared
	h := profiled_mutex_lock(&shared.mu, .Runtime_State)
	testing.expect(t, h != 0, "acquire time returned")
	waiter := thread.create_and_start_with_poly_data(&shared, proc(s: ^Shared) {
		sync.sema_post(&s.held)
		w := profiled_mutex_lock(&s.mu, .Runtime_State)
		profiled_mutex_unlock(&s.mu, .Runtime_State, w)
	})
	sync.sema_wait(&shared.held)
	time.sleep(20 * time.Millisecond)
	profiled_mutex_unlock(&shared.mu, .Runtime_State, h)
	thread.join(waiter)
	thread.destroy(waiter)
	p := lock_profile_snapshot()[.Runtime_State]
	testing.expect_value(t, p.acquisitions, i64(2))
	testing.expect_value(t, p.holds, i64(2))
	testing.expect_value(t, p.contended, i64(1))
	testing.expectf(t, p.max_wait_ns >= 10 * i64(time.Millisecond), "waiter waited behind the holder: %d ns", p.max_wait_ns)
	testing.expect(t, p.wait_ns >= p.max_wait_ns, "max is part of the sum")
	testing.expectf(t, p.hold_ns >= 10 * i64(time.Millisecond), "hold measured: %d ns", p.hold_ns)
	other := lock_profile_snapshot()[.Uow_Tx]
	testing.expect_value(t, other.acquisitions, i64(0))
}
