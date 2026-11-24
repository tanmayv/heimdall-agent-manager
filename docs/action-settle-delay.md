# Action trigger settle delay

Event triggers accept `delay_s` from 0 to 86400. The CLI's `--delay 10m`
applies to the preceding `--trigger` or `--trigger-json`; zero delivers immediately.
The event trigger editor also exposes the delay in seconds.

A pending timer belongs to a trigger and settle key. New occurrences for that
key restart its timer and replace the event snapshot; redelivery does not.
Different keys have independent timers. Once ready, a key waits for any open
run with a different key to finish, including its awaiting-read period.
Completion checks an indexed pending-run lookup and writes an outbox event only
when a ready settle run is waiting. That event wakes waiting keys without a timer loop.
Ready runs still obey the action's minimum interval. Same-key ready runs retain
the existing join behavior. Immediate triggers retain their existing join behavior.

The timer payload carries its scheduled deadline: a matching resume hint is
trusted despite small clock differences, while an obsolete debounce hint cannot
advance a newer deadline. Changing, disabling, or removing the trigger invalidates
its delayed snapshot. Unsupported schedules appear separately in run history.

Event descriptors may provide `settle_key` and `still_valid` callbacks.
Validity uses one indexed local chain lookup after rate limiting and before
planning; immediate runs skip it. Planning may start an instance, so invalid
snapshots never reach it. A chain reopening during planning is an accepted race.
Chain state snapshots compare state plus completion/update timestamp; work
completion compares work revision. Prompt metadata includes `chain_id` and
`event_id` when available.
