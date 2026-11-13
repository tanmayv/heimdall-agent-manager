# Context rollover recovery

The Bridge gives each rollover cycle a fresh 128-bit OS-random identity, encoded
as a `rollover_` request ID. It owns this identity until replacement or instance
cleanup. Retries in that cycle reuse it; a Bridge state reset starts a new
identity. The Hub continues to deduplicate by instance and request ID, preserving
the original handoff body, timestamp and read state. No schema migration is needed.
Resending after a lost CLI reply also reuses the cycle identity while restart is
pending, without resetting the restart state or requesting a second restart.

A saved handoff still requires a trusted main-agent idle signal before restart.
Extension Stop and explicit `pane_diff` idle qualify; wrapper idle, subagent
events, `waiting_user` and `waiting_approval` do not. Duplicate signals request
only one restart. Readiness completes that cycle and resets context accounting.
The instance and its task ownership survive; timers do not prove process death.

Notification withholding is separate from restart eligibility:

- A handoff request retries once after five minutes, then ends with an alert and
  ten-minute cooldown.
- Persistence taking five minutes ends that rollover attempt, releases message
  wakes and alerts. A late store acknowledgement may still represent a durable
  handoff, but cannot arm a restart after timeout or advance a newer cycle.
- A saved handoff waiting five minutes for safe idle releases message wakes and
  alerts once. It remains eligible for its single restart at the next trusted idle.
- A requested restart without readiness after five minutes releases message
  wakes and alerts once. It does not force another restart or clear ownership;
  later readiness can still complete the pending rollover.
- Holding message wakes has an absolute ten-minute limit from the initial
  request, even if persistence retries keep changing phase.
- Failed queued-wake delivery is retained and retried on the next five-second
  tick or readiness, using the instance's current PTY. New messages bypass
  withholding after recovery; queue overflow also falls back to immediate
  delivery rather than acknowledging a discarded wake.

Delayed request/restart actions and persistence/restart callbacks carry their
cycle identity. Older work cannot advance a replacement cycle. Transition logs
include the instance, cycle ID and old/new phases, without handoff bodies or
credentials. Safe-idle activity protection remains until the cycle completes.

The focused rollover state-machine tests use isolated instances and controlled
timestamps. HTTP tests cover immutable retry acknowledgements, distinct handoffs
and chat visibility; UI tests cover separate previous-context rows. These checks
do not replace a deployed Bridge/provider end-to-end test.
