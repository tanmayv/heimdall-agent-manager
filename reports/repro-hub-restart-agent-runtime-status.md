# Verification Report: Agent Runtime Status Behavior on Local Hub Restart

**Date:** 2026-10-03  
**Target Repository:** `/usr/local/google/home/tanmayvijay/heimdall-agent-manager`  
**Requirement IDs:** REQ-VERIFY-1, REQ-VERIFY-2, REQ-VERIFY-3, REQ-VERIFY-4  
**Investigator:** Worker (`inst_18db08419485c647`)

---

## 1. Executive Summary & Verdict

**Verdict:** **REPRODUCED (CONFIRMED)**

When the local Hub process is restarted while an agent instance is actively running:
1. The host agent process is **terminated / reaped** by the bridge upon reconnection (`bridge agent reconcile: reaped orphan instance inst_...`).
2. The Hub API (`GET /api/v1/agent-instances/:id`) and SQLite database (`agent_instances` table) **continue to report `runtime_status: "running"`** (along with `startup_status: "ready"` and `activity_status: "idle"`).
3. The phantom "running" status persists indefinitely (verified across immediate observation and an extended 10+ second settle window) even though no physical host process or session exists for the agent.

Per user instructions, no root cause analysis (RCA) or source code modifications were performed; this report captures empirical reproduction steps, exact commands, process listings, database queries, and log records.

---

## 2. Test Environment & Configuration

- **Host Machine:** `tanmayvijay.c.googlers.com` (Linux)
- **Local Dev Stack:**
  - Hub: `127.0.0.1:8081` (SQLite DB: `hub.db`)
  - Dev-Proxy: `127.0.0.1:8080` (Injects auth header for user `tanmay`)
  - Dev Bridge: Port `49327`, local endpoint port `49328`, run dir `/tmp/heimdall-bridge-dev`
- **Bridge Identifier:** `brg_18db085baa0bb9cc` (label: `dev-local`)
- **Agent Under Test:** `agt_18db085ba624a4b4` (`worker`)
- **Agent Instance Under Test:** `inst_18db086996a1e95c`
- **Isolation Guarantee:** Production Hub (`hub.mundus.in`) and production Mundus bridge (`brg_18d03379a7d6d47b` on ports 49323/49324) were completely untouched.

---

## 3. Step-by-Step Reproduction Evidence

### Step 3.1: Starting the Local Dev-Stack

The dev-stack was started via `scripts/dev-stack.sh enroll && scripts/dev-stack.sh start`.

```text
[dev-stack] creating a bridge enrollment via dev-proxy (user tanmay)
[dev-stack] exchanging enrollment token for a durable bridge token
  bridge enroll: POST http://127.0.0.1:8081/api/v1/bridges/enroll (enrollment_token=hbe_18db..., len=20)
  bridge enroll: hub accepted (HTTP 201)
  bridge_token_file /usr/local/google/home/tanmayvijay/heimdall-agent-manager/.run-logs/bridge/bridge-token
  bridge enroll SUCCESS: enrolled as bridge_id=brg_18db085baa0bb9cc hub_url=http://127.0.0.1:8081
[dev-stack] bridge config: ham_ctl_bin -> /usr/local/google/home/tanmayvijay/heimdall-agent-manager/result-ctl/bin/ham-ctl
[dev-stack] bridge config: stripped [[peer]] blocks
[dev-stack] enrolled; token written to /usr/local/google/home/tanmayvijay/heimdall-agent-manager/.run-logs/bridge/bridge-token and config updated.
[dev-stack] starting hub on 127.0.0.1:8081
[dev-stack] starting dev-proxy on 127.0.0.1:8080 -> hub
[dev-stack] bridge config: ham_ctl_bin -> /usr/local/google/home/tanmayvijay/heimdall-agent-manager/result-ctl/bin/ham-ctl
[dev-stack] bridge config: stripped [[peer]] blocks
[dev-stack] starting bridge on port 49327 -> hub
=== dev-stack status ===
  hub: RUNNING (pid 1745478)
  devproxy: RUNNING (pid 1745510)
  bridge: RUNNING (pid 1745525)
--- listeners ---
  ham-hub 127.0.0.1:8081
  ham-dev-p 127.0.0.1:8080
  ham-bridg 127.0.0.1:49328
  ham-bridg 127.0.0.1:49327
--- health ---
  hub /api/v1/health: OK
```

Bridge log confirmed runtime readiness:
```text
bridge hub runtime ready
```

---

### Step 3.2: Launching Test Agent Instance & Verifying Live State

A test agent instance was launched on the local dev bridge via `POST http://127.0.0.1:8080/api/v1/agent-instances`:

```bash
curl -s -X POST http://127.0.0.1:8080/api/v1/agent-instances \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"agt_18db085ba624a4b4","bridge_id":"brg_18db085baa0bb9cc","provider":"jetski"}'
```

**Launch Response:**
```json
{
  "data": {
    "agent_instance_id": "inst_18db086996a1e95c",
    "agent_id": "agt_18db085ba624a4b4",
    "bridge_id": "brg_18db085baa0bb9cc",
    "display_name": "worker #1",
    "provider": "jetski",
    "tier": "smart",
    "project_id": "",
    "project_path": "",
    "chain_id": "chain_18db0869962e713f",
    "conversation_id": "chat_18db086996a1f94c",
    "runtime_status": "launching",
    "startup_status": "starting",
    "activity_status": "unknown",
    "last_applied_seq": 0,
    "run_count": 1,
    "started_at": "2026-10-03T13:35:26Z"
  }
}
```

#### Pre-Restart State Verification:

1. **Hub API (`GET /api/v1/agent-instances/inst_18db086996a1e95c`):**
   ```json
   {
     "data": {
       "agent_instance_id": "inst_18db086996a1e95c",
       "runtime_status": "running",
       "startup_status": "ready",
       "activity_status": "idle",
       "last_applied_seq": 1791038128497,
       "last_seen_at": "2026-10-03T13:35:28Z",
       "updated_at": "2026-10-03T13:35:28Z"
     }
   }
   ```

2. **Hub Database (`hub.db` `agent_instances` table):**
   ```sql
   SELECT agent_instance_id, runtime_status, startup_status, activity_status, last_seen_at
   FROM agent_instances WHERE agent_instance_id='inst_18db086996a1e95c';
   ```
   **Output:**
   ```text
   inst_18db086996a1e95c|running|ready|idle|2026-10-03T13:35:28Z
   ```

3. **Host Process Reality:**
   ```text
   UID          PID    PPID  C STIME TTY          TIME CMD
   tanmayv+ 1747339 1745538  0 19:05 pts/408  00:00:00 bash /tmp/mock-agent.sh --model default First, run: ./.heimdall/bin/ham-ctl agent start-success. ...
   ```
   - PPID: `1745538` (`ham-pty-host daemon --socket /tmp/heimdall-bridge-dev/pty-host-brg_dev_local.sock`)
   - Child process: `PID 1747701 sleep 5` (idle loop active)
   - Host agent was unequivocally alive.

---

### Step 3.3: Restarting the Local Hub Process

The dev Hub process (PID 1745478) was terminated with `kill -9` and restarted, leaving the dev-bridge (PID 1745525), dev-pty-host (PID 1745538), dev-proxy (PID 1745510), and the agent process (PID 1747339) running undisturbed.

```bash
kill -9 1745478
nohup ./result-hub/bin/ham-hub \
  --listen 127.0.0.1:8081 --db hub.db \
  --migrations-dir src/hub/repository/sqlite/migrations \
  --trusted-proxy-cidr 127.0.0.1/32 > .run-logs/hub.log 2>&1 &
echo $! > .run-logs/hub.pid
```

**New Hub PID:** `1749678`  
Network sockets verified:
```text
COMMAND       PID        USER FD   TYPE   DEVICE SIZE/OFF NODE NAME
ham-bridg 1745525 tanmayvijay 5u  IPv4 79373969      0t0  TCP 127.0.0.1:47312->127.0.0.1:8081 (ESTABLISHED)
ham-hub   1749678 tanmayvijay 4u  IPv4 79353730      0t0  TCP 127.0.0.1:8081 (LISTEN)
ham-hub   1749678 tanmayvijay 5u  IPv4 79353731      0t0  TCP 127.0.0.1:8081->127.0.0.1:47312 (ESTABLISHED)
```

---

### Step 3.4: Post-Restart Observations & Evidence

#### 1. Bridge Logs (`.run-logs/bridge.log`):

Upon Hub restart, the bridge detected socket closure, reconnected to the new Hub runtime WebSocket, and executed agent reconciliation:

```text
bridge hub runtime: connection closed, reconnecting…
bridge hub runtime: cannot connect WS ws://127.0.0.1:8081/api/v1/bridge-ws — proxy/tunnel down, hub unreachable, or TLS failed (attempt 1)
bridge hub runtime ready
bridge agent reconcile: reaped orphan instance inst_18db086996a1e95c
```

#### 2. Host Process Reality Post-Restart:

Checking PID 1747339:
```bash
ps -fp 1747339
pgrep -fa mock-agent
```
**Output:**
```text
UID          PID    PPID  C STIME TTY          TIME CMD
(empty - process 1747339 does not exist)

pgrep output:
(no mock-agent processes running)
```
**Host process is completely dead and terminated.**

#### 3. Hub API State Post-Restart:

Querying `GET http://127.0.0.1:8080/api/v1/agent-instances/inst_18db086996a1e95c`:
```json
{
  "data": {
    "agent_instance_id": "inst_18db086996a1e95c",
    "agent_id": "agt_18db085ba624a4b4",
    "bridge_id": "brg_18db085baa0bb9cc",
    "display_name": "worker #1",
    "provider": "jetski",
    "tier": "smart",
    "project_id": "",
    "project_path": "",
    "chain_id": "chain_18db0869962e713f",
    "conversation_id": "chat_18db086996a1f94c",
    "runtime_status": "running",
    "startup_status": "ready",
    "activity_status": "idle",
    "last_applied_seq": 1791038128497,
    "run_count": 1,
    "started_at": "2026-10-03T13:35:26Z",
    "stopped_at": "",
    "last_seen_at": "2026-10-03T13:36:48Z",
    "updated_at": "2026-10-03T13:36:48Z",
    "current_task_id": "",
    "current_task_role": "none"
  }
}
```
**Hub API still reports `runtime_status: "running"`.**

#### 4. Hub Database State Post-Restart:

Querying SQLite database `hub.db`:
```sql
SELECT agent_instance_id, runtime_status, startup_status, activity_status, last_seen_at, updated_at
FROM agent_instances WHERE agent_instance_id='inst_18db086996a1e95c';
```
**Output:**
```text
[('inst_18db086996a1e95c', 'running', 'ready', 'idle', '2026-10-03T13:36:48Z', '2026-10-03T13:36:48Z')]
```
**Hub DB still stores `runtime_status = 'running'`.**

#### 5. Settle Window Check (10+ seconds later):

Re-queried after 10+ seconds:
- Process check: Still dead (`ps -fp 1747339` returned empty).
- Hub DB: Still `running`.
- Hub API: Still `running`.

---

## 4. Comparison Summary Table

| Metric / Dimension | Before Hub Restart | After Hub Restart (Physical Reality) | After Hub Restart (Hub Reported) | Discrepancy |
| :--- | :--- | :--- | :--- | :--- |
| **Agent Host Process** | Alive (PID `1747339`) | **Dead / Reaped** (reaped by bridge reconcile) | N/A | Process terminated |
| **Pty-Host Session** | Active | Reaped | N/A | Session gone |
| **Bridge Log** | `bridge hub runtime ready` | `bridge agent reconcile: reaped orphan instance inst_...` | N/A | Bridge marked instance as orphan |
| **Hub API `runtime_status`**| `"running"` | **Stopped / Dead** | **`"running"`** | **Mismatch: Reports running while dead** |
| **Hub DB `runtime_status`** | `'running'` | **Stopped / Dead** | **`'running'`** | **Mismatch: Database record stale** |

---

## 5. Clean Teardown

The local dev stack was cleanly stopped using `./scripts/dev-stack.sh stop`.
Verification confirmed that:
- Local Hub (`127.0.0.1:8081`) stopped.
- Local Dev-Proxy (`127.0.0.1:8080`) stopped.
- Local Dev-Bridge (`49327/49328`) stopped.
- Production Mundus Hub and bridge were completely unaffected.
