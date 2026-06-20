# Test Agent Implementation Plan

## Goal

Add a standalone `ham-test-agent` binary for integration/load testing the daemon, wrapper, message provider, and RPC message flow.

The test agent should behave like a simple autonomous agent:

- send messages to configured target agents at configured frequencies
- fetch actual messages from daemon RPC
- log every received actual message
- track sent/received message counts and byte counts
- write stats files for large-scale validation

Real-world assumption: a real agent such as `pi` may learn its token from prompt/context/AGENTS.md. For testing, `ham-test-agent` will receive token and identity through explicit CLI flags.

WebSocket remains daemon/wrapper notification-only. `ham-test-agent` should not depend on WS. It should actively fetch via RPC to simulate the agent reading messages.

## Add Binary

Create:

```text
src/test_agent/main.odin
```

Update `flake.nix` with package/app:

```bash
nix build .#ham-test-agent
nix run .#test-agent
```

Binary name:

```text
ham-test-agent
```

## CLI Arguments

Support:

```text
--daemon-url <url>
--agent-instance-id <id>
--agent-token <token>
--targets <target:freq_ms,target:freq_ms>
--duration-sec <seconds>
--message-size <bytes>
--stats-dir <path>
--log-dir <path>
--fetch-interval-ms <ms>
```

Defaults:

```text
--daemon-url http://127.0.0.1:49322
--duration-sec 60
--message-size 256
--fetch-interval-ms 500
--stats-dir /tmp/ham-test/stats
--log-dir /tmp/ham-test/logs
```

Required:

```text
--agent-instance-id
--agent-token
```

`--targets` may be empty for receive-only agents.

## Target Format

```text
agent_instance_id:frequency_ms
```

Example:

```text
coder-agent@b:1000,coder-agent@c:500
```

Maintain per-target state:

```text
target_agent_instance_id
frequency_ms
next_send_unix_ms
sent_seq
```

## Runtime Loop

Run until duration expires.

Loop every 50-100ms:

1. For each target, if `now >= next_send_unix_ms`:
   - generate deterministic body
   - call `/agent-rpc` with canonical `send_message`
   - update sent counters
   - schedule next send

2. If `now >= next_fetch_unix_ms`:
   - call `/agent-rpc` with canonical `fetch_messages`
   - `include_read=false`
   - log each returned actual message
   - update received counters

3. Periodically write stats JSON.

## Message Body

Generate deterministic body:

```text
from=<agent>
to=<target>
seq=<n>
created_unix_ms=<ms>
payload=xxxx...
```

Pad/truncate to approximately `--message-size` bytes.

## RPC Calls

### Send

```json
{
  "agent_token": "agent_coder-agent@a",
  "action": "send_message",
  "target_agent_instance_id": "coder-agent@b",
  "payload": "..."
}
```

### Fetch

```json
{
  "agent_token": "agent_coder-agent@b",
  "action": "fetch_messages",
  "conversation_id": "conv_coder-agent_b",
  "include_read": false
}
```

Derive conversation ID like daemon:

```text
conv_ + agent_instance_id with non [A-Za-z0-9_-] chars replaced by _
```

Example:

```text
coder-agent@b -> conv_coder-agent_b
```

## Logging

Incoming messages:

```text
<log-dir>/<agent_instance_id>.incoming.jsonl
```

Each line:

```json
{
  "ts_unix_ms": 123,
  "message_id": "msg_1",
  "conversation_id": "conv_coder-agent_b",
  "from_agent_instance_id": "coder-agent@a",
  "target_agent_instance_id": "coder-agent@b",
  "bytes": 256,
  "body": "..."
}
```

Optional errors:

```text
<log-dir>/<agent_instance_id>.errors.log
```

## Stats

Stats file:

```text
<stats-dir>/<agent_instance_id>.stats.json
```

Shape:

```json
{
  "agent_instance_id": "coder-agent@a",
  "sent_messages": 120,
  "sent_bytes": 30720,
  "received_messages": 118,
  "received_bytes": 30208,
  "send_errors": 0,
  "fetch_errors": 0,
  "fetch_calls": 60,
  "started_unix_ms": 123,
  "updated_unix_ms": 456
}
```

Atomic temp+rename write is preferred if easy; direct overwrite is OK for first POC.

## Wrapper Integration

For first POC, pass explicit args in wrapper config command.

Example:

```toml
[wrapper]
command = [
  "ham-test-agent",
  "--daemon-url", "http://127.0.0.1:49322",
  "--agent-instance-id", "coder-agent@a",
  "--agent-token", "agent_coder-agent@a",
  "--targets", "coder-agent@b:1000",
  "--duration-sec", "60",
  "--message-size", "256",
  "--stats-dir", "/tmp/ham-test/stats",
  "--log-dir", "/tmp/ham-test/logs"
]
```

Later wrapper can template/inject token and instance after registration. For now explicit args are acceptable.

## Smoke Test

Start daemon.

Start two wrappers using `ham-test-agent` commands:

- `coder-agent@a` targets `coder-agent@b`
- `coder-agent@b` targets `coder-agent@a`

Run for 30-60 seconds.

Verify:

```text
/tmp/ham-test/stats/coder-agent@a.stats.json
/tmp/ham-test/stats/coder-agent@b.stats.json
/tmp/ham-test/logs/coder-agent@a.incoming.jsonl
/tmp/ham-test/logs/coder-agent@b.incoming.jsonl
```

Expected:

- sent counts increase
- received counts increase
- incoming logs contain actual messages
- WS remains metadata-only

## Constraints

- Canonical RPC actions only:
  - `send_message`
  - `fetch_messages`
- Do not depend on WS in `ham-test-agent`.
- Do not send actual message bodies over WS.
- Actual messages move through RPC/provider only.
- Keep implementation simple and POC-friendly.
