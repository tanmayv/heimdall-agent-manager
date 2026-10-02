# Heimdall Bridge & Agent Telemetry

This directory contains the Telegraf configuration template and validation runner for Heimdall bridge and agent telemetry (fulfilling requirements **REQ-TEL-3** and **REQ-TEL-4**).

The telemetry pipeline collects process-level memory (RSS, VIRT) and CPU metrics for Heimdall daemons and child worker agent processes, along with host-level baselines, and exports them via Prometheus format across both Linux and macOS platforms.

---

## Files

- **`telegraf.conf.template`**: Cross-platform configuration template parameterized with environment variables.
- **`validate_telegraf.sh`**: Automated validation script that checks Telegraf syntax, substitutes test variables, runs `--test`, and verifies metric emission.
- **`README.md`**: Architecture documentation, metric definitions, and cross-platform compatibility notes.

---

## Configuration Details (`telegraf.conf.template`)

The configuration consists of:

1. **`[agent]`**:
   - `interval = "10s"`: Collects metrics every 10 seconds.
   - `round_interval = true`: Synchronizes collection with clock intervals (e.g., :00, :10).
   - Buffer limits configured to absorb temporary collector hiccups.

2. **`[global_tags]`**:
   - `bridge_id = "${HEIMDALL_BRIDGE_ID}"`: Identifies the originating Heimdall bridge instance.
   - `bridge_host = "${HOSTNAME}"`: Hostname where the bridge runs.

3. **`[[inputs.procstat]]`**:
   - `pattern = "(ham-bridge|ham-ctl|ham-pty-host|node|python|jetski|claude)"`: Regex matching all Heimdall daemon, CLI, PTY host, and AI/agent worker processes.
   - `tag_with = ["pid", "cmdline"]`: Tags each metric series with the process ID and command-line invocation for granular agent instance tracking.
   - **Cross-platform**: Intentionally excludes Linux-only `systemd_unit` and `cgroup` flags.

4. **`[[inputs.cpu]]` & `[[inputs.mem]]`**:
   - Collects host-level CPU utilization (`percpu = false, totalcpu = true`) and memory stats (total, available, used, cached) for baseline context.

5. **`[[outputs.prometheus_client]]`**:
   - `listen = "127.0.0.1:${TELEMETRY_PORT:-9273}"`: Serves a Prometheus metrics endpoint locally on the specified port (defaults to `9273`).

---

## Validation Runner (`validate_telegraf.sh`)

The validation script ensures the configuration template is syntactically and semantically correct:

```bash
bash tools/telemetry/validate_telegraf.sh
```

### Execution Steps
1. Detects `telegraf` on `PATH` or falls back automatically to `nix-shell -p telegraf`.
2. Substitutes environment variables (`HEIMDALL_BRIDGE_ID=brg_test`, `TELEMETRY_PORT=9273`, and `HOSTNAME`) into `/tmp/telegraf-test.conf`.
3. Runs `telegraf --config /tmp/telegraf-test.conf --test`.
4. Asserts that `procstat`, `cpu`, and `mem` metrics are produced.
5. Verifies the presence of `bridge_id` tags and critical process fields: `memory_rss`, `memory_vms`, `cpu_time_user`, and `cpu_time_system`.

---

## Emitted Metrics

### Process Metrics (`procstat`)

| Metric Field | Type | Description |
|---|---|---|
| `memory_rss` | Gauge (bytes) | Resident Set Size (physical memory occupied by process) |
| `memory_vms` | Gauge (bytes) | Virtual Memory Size (total address space allocated) |
| `cpu_time_user` | Counter (seconds) | Cumulative CPU time spent in user mode |
| `cpu_time_system` | Counter (seconds) | Cumulative CPU time spent in kernel/system mode |
| `cpu_usage` | Gauge (percent) | Percentage of CPU utilized |
| `num_threads` | Gauge (integer) | Number of active threads in the process |

**Tags**:
- `bridge_id`: Heimdall bridge instance identifier (e.g. `brg_test`).
- `bridge_host`: Hostname where the bridge runs.
- `pid`: Process identifier.
- `cmdline`: Full process command line.
- `process_name`: Process binary name.
- `pattern`: The regex filter pattern used for matching.

### Host Metrics (`cpu`, `mem`)

- **`cpu`**: `usage_user`, `usage_system`, `usage_idle`, `usage_iowait`.
- **`mem`**: `total`, `available`, `used`, `free`, `buffered`, `cached`, `used_percent`.

---

## Cross-Platform Compatibility Notes

### Linux (`procfs`)
- Telegraf's `procstat` plugin inspects `/proc` (`/proc/<pid>/stat`, `/proc/<pid>/status`, and `/proc/<pid>/cmdline`).
- PID resolution uses `pgrep -f` by default.
- By omitting systemd unit queries (`systemd_unit`, `include_systemd_children`), this configuration functions seamlessly across traditional Linux distributions, container runtimes (Docker, Podman), and non-systemd environments.

### macOS (Mach / `libproc`)
- macOS does not have `/proc`. Instead, Telegraf relies on Darwin's native `libproc` (`proc_pidinfo`, `proc_pidpath`) and Mach kernel APIs (`mach_vm`).
- Command lines and arguments are retrieved through Darwin sysctl (`KERN_PROCARGS2`).
- BSD `pgrep` is available natively on macOS and accurately resolves matching processes.
- Memory statistics map Mach task memory (`resident_size`, `virtual_size`) directly to `memory_rss` and `memory_vms`.
- CPU times map thread/task accounting info (`user_time`, `system_time`) to `cpu_time_user` and `cpu_time_system`.
- **Permissions**: Running within a user's terminal session or launchd agent allows monitoring all processes owned by that user without requiring `sudo` privileges.
