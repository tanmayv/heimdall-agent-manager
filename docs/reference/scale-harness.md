# Task engine load harness (Scale H)

An opt-in, repeatable load test for the hub task engine (`src/hub/service/taskv2`). It
measures what the remaining scaling options depend on: DB reads per event, grant and submit
latency under concurrent callers, hub boot time as Done history grows, and how much time
callers spend waiting on the hub's hot locks.

It never runs in the default test suites. The test (`taskv2.test_scale_harness` in
[scale_harness_test.odin](../../src/hub/service/taskv2/scale_harness_test.odin)) is only
compiled in with `-define:HEIMDALL_SCALE_HARNESS=true`; the helpers around it always compile,
so it cannot rot unnoticed.

## Running it

```bash
nix develop -c scripts/scale-harness.sh                         # this checkout
nix develop -c scripts/scale-harness.sh --rev 6ae3d5c3          # another commit
python3 scripts/scale_report.py ~/.cache/heimdall-scale/result-<a>.json ~/.cache/heimdall-scale/result-<b>.json > report.md
```

`--rev` builds the harness in a temporary detached worktree at that commit. When the commit
predates the lock profile (below), the commit that added it is applied there first; the
harness file is copied in unchanged. `--label` names the result, `--out` sets the JSON path
(default `~/.cache/heimdall-scale/result-<label>.json`).

Sizes and placement come from the environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `HEIMDALL_SCALE_CHAINS` | 100 | chains in the load scenario |
| `HEIMDALL_SCALE_TASKS` | 1000 | tasks per chain |
| `HEIMDALL_SCALE_SERIAL_OPS` | 300 | events in the serial phase |
| `HEIMDALL_SCALE_THREADS` | 8 | concurrent callers |
| `HEIMDALL_SCALE_OPS` | 150 | events per caller in the concurrent phase |
| `HEIMDALL_SCALE_BOOT` | `1000,10000,100000` | Done-task counts for the boot phase |
| `HEIMDALL_SCALE_CLOCK_STEP` | 0 | fake-clock seconds each chaos round advances (see *Rematch storm*) |
| `HEIMDALL_SCALE_STORM_MAX_DONE` | 10000 | largest boot size that also runs the Rematch storm |
| `HEIMDALL_SCALE_DB_DIR` | `~/.cache/heimdall-scale` | database directory (WAL, `synchronous=NORMAL`, as the hub runs); `memory` uses `:memory:` |
| `HEIMDALL_SCALE_ODIN_FLAGS` | (none) | extra Odin flags, e.g. `-o:speed` |

The full default run takes tens of minutes per commit. A smoke run:
`HEIMDALL_SCALE_CHAINS=4 HEIMDALL_SCALE_TASKS=60 HEIMDALL_SCALE_THREADS=2 HEIMDALL_SCALE_OPS=40 HEIMDALL_SCALE_SERIAL_OPS=40 HEIMDALL_SCALE_BOOT=1000`.

## Scenario

- Chains are seeded with SQL. Each task gets an event log that folds to its seeded state
  (`created`, a `migrated` event carrying the state, and for Done tasks `submitted`,
  `approved`, `merged`), so refold leaves the rows alone. The mix is 70% done, 15% ready for
  the fleet's worker agent and 15% in review owed to an agent outside the fleet.
- Each chain has a fleet of `agt_w` (capacity 3) and `agt_r` (capacity 2): three worker and
  two reviewer instances spread over four bridges, plus a coordinator. One `fleet_changed`
  per chain places the first work before anything is measured.
- **Serial phase:** one caller drives lease next, then submit (work lease) or review approve
  (review lease), round-robin over the instances. Each event is measured alone, so its
  repository reads (the `Read_Counter` wrapper from `lease_next_cost_test.odin`), SELECT and
  write statements and SELECT VM steps (from the SQLite telemetry counters) are exact.
- **Concurrent phase:** N caller threads drive the same loop over their share of the
  instances while a chaos thread repeatedly takes one bridge offline (callers on it go quiet,
  its instances turn unreachable and hit `on_instance_terminal`), advances the clock by
  `HEIMDALL_SCALE_CLOCK_STEP` (default 0), fires due timers, and brings the bridge back
  (`on_bridge_hello`). Latency percentiles and lock waits come from this phase.
- **Boot phase:** for each size, 100 chains holding that many Done tasks in total plus 10
  ready and 10 in-review tasks each and the fleet's confirmed leases; then a fresh `Service`
  (a hub restart) runs `rebuild_timers` alone, and another runs the whole `boot`. Up to
  `HEIMDALL_SCALE_STORM_MAX_DONE`, the clock then moves 61 s and one `fire_due` pass runs in
  one scratch arena: the Rematch storm below.

## Rematch storm

`arm_task_timers` arms three Rematch one-shots (60, 180, 600 s) for every Ready and In-review
task, and `boot` re-arms them for all of them. When the first delay passes, the hub's timer
thread pops every one in a single tick; each runs `match_chain_in_uow` (a full chain match)
and everything the tick allocates lives in the thread's temp arena until the tick ends. At
100 chains x 1,000 tasks (about 30,000 Ready / In-review tasks) that tick grows by roughly
3 GB a minute and was OOM-killed at 57 GB, so the load phase keeps the clock still by
default and the boot phase measures the storm on its own (timers fired, tick time, RSS
growth). `HEIMDALL_SCALE_CLOCK_STEP=30` reproduces it inside the load phase.

A **grant** is any event whose transaction pushed at least one grant (observed as a
`wake_agent` with a `run[]` entry after commit) or a `lease next` that granted inline. Grants
are mostly pushed by the matcher inside a submit or review transaction.

## Lock-wait profile

[lock_profile.odin](../../src/hub/platform/dbtelemetry/lock_profile.odin) counts, per lock,
acquisitions, contended acquisitions (waited at least 2 µs), summed and maximum wait, and
summed hold: `sqlite.tx_mutex` (the single unit-of-work writer), taskv2
`Service.state_mutex` (through `state_lock` / `state_unlock`), the taskv2 timer-heap mutex
and the bridge runtime connection `state_mutex` (wait only).

It is off by default and independent of `HEIMDALL_DB_TELEMETRY`; only the harness calls
`dbt.set_lock_profile(true)`. Off, each acquisition costs one relaxed atomic load and a
branch; the harness measures that against a plain `sync.mutex_lock` in every run
(`lock_profile_overhead_ns`).

Shares reported: `wait_share_of_caller_time` = summed wait / (wall time x callers);
`hold_share_of_wall` = summed hold / wall time (for `tx_mutex`, how busy the single writer
was).

## Limits

- One process and one SQLite connection, as in the hub; no HTTP or bridge network I/O (wakes
  are observed, not sent). Latencies are engine plus SQLite time, a lower bound on what an
  agent sees.
- DB telemetry runs in `basic` mode (the hub default), which the per-event attribution needs.
- The clock is the fixtures' fake clock; the chaos thread advances it 30 s per round, so
  time-based timers fire during the run.
