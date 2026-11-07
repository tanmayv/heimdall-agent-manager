# Configure local agent launch resources

An ordinary manual launch, warm wake or managed provider test proposes an inert
local draft. It cannot activate credentials, replace bootstrap files or start a
child until the preparing enrolled browser approves that exact configuration.
User shell sessions are separate. Task-owner authorization and renewal remain
separate from this device resource allocation.

## Operator boundary

Resource configuration is an explicit host operation. `ham-bridge executor sign`
uses the selected Bridge's existing protected keystore identity. Its authority is
OS-account ownership/access to that keystore, the same native CLI boundary as
Bridge setup/service management. This does **not** distinguish a human from an
agent or another process running with the same OS account and keystore access.
An agent token is not operator authority. There is no signing RPC, private-key
export, imported signing key, automatic provisioning or signing during launch.

The local socket accepts only already signed policy/directory records from the
pinned operator key. Import independently verifies account, Bridge, key, signature,
revision and current canonical filesystem path. It uses the running Bridge's
single journal writer under startup/vault/configuration gates. Reallocation
requires drained resources; retries preserve exact signed records.

## Explicit allocation

Use the selected Bridge's actual configuration and the `--local-run-dir` from its
service invocation. The commands below are examples for an operator to run on the
host, not instructions to modify the live installation during a code review.

```bash
ham-bridge executor identity --config /path/to/bridge.toml
```

Copy `account_id`, `executor_bridge_id` and `key_id` from that public identity
output into both records. Supply an explicit finite capacity, named profile and
slots. The example below allocates one device slot; it does not borrow a Hub
entitlement or generate a task/chain/lease.

```json
{
  "protocol_version": "1",
  "account_id": "REPLACE_ACCOUNT",
  "executor_bridge_id": "REPLACE_BRIDGE",
  "policy_revision": "1",
  "device_capacity": "1",
  "slots_json": "[{\"slot_id\":\"local_agent_1\",\"provider_profile\":\"claude\",\"enabled\":\"1\"}]",
  "key_id": "REPLACE_KEY_ID",
  "signature": "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
}
```

Choose an existing specific canonical directory inside the configured filesystem
root. Do not substitute a broad home/root directory or create a temporary fallback.
For a project launch, this must match its effective project path. A no-project
launch needs a single unambiguous enabled mapping; otherwise configuration must
be made unambiguous before retrying.

```json
{
  "protocol_version": "1",
  "account_id": "REPLACE_ACCOUNT",
  "executor_bridge_id": "REPLACE_BRIDGE",
  "directory_id": "local_workspace",
  "revision": "1",
  "directory_path": "/explicit/canonical/workspace",
  "enabled": "1",
  "key_id": "REPLACE_KEY_ID",
  "signature": "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
}
```

Save these as `policy.json` and `directory.json`. Signing requires a new output
filename and prints that filename; inspect the supplied values before signing.
Capacity is bounded by the existing contract (maximum 128). Policy and directory
revisions advance by one. Installation rejects a revision change while resources
are charged.

```bash
ham-bridge executor sign --config /path/to/bridge.toml --kind policy --file policy.json --output policy-signed.json
ham-bridge executor sign --config /path/to/bridge.toml --kind directory --file directory.json --output directory-signed.json
ham-bridge executor import --config /path/to/bridge.toml --local-run-dir /actual/bridge/run --kind policy --file policy-signed.json
ham-bridge executor import --config /path/to/bridge.toml --local-run-dir /actual/bridge/run --kind directory --file directory-signed.json
ham-bridge executor inspect --config /path/to/bridge.toml --local-run-dir /actual/bridge/run --kind policy --file policy-signed.json
ham-bridge executor inspect --config /path/to/bridge.toml --local-run-dir /actual/bridge/run --kind directory --file directory-signed.json
```

Inspect returns the current signed record, revision, device capacity, live resource
count and journal incarnation. It returns no startup token or child-control key.
An older genuine signed record may identify the corresponding current record for
readback; it cannot roll a revision back or change the installed allocation.

## Approve and cancel a launch

Request the ordinary launch, then open its instance details. **Prepare review**
claims the draft for the current enrolled browser. Review provider/model/profile,
purpose, protected directory revision, slot/policy and launch generation before
**Approve exact launch**. **Inspect current state** retrieves a fresh signed
observation. **Cancel launch** releases an undispatched admission; dispatched or
uncertain children remain charged until an exact trusted stop/absence observation.

The browser retains unresolved signed operations and draft references as vault
ciphertext in session storage. **Retry retained operation** sends the original
signed bytes after a lost reply or page reload. A historical success never revives
a cancelled launch or proves readiness. Controls remain reachable after readiness
clears the instance's error. Enrollment is verified before and after browser relay
I/O and freshly at the native dispatch boundary; bootstrap delays, revocation,
mapping replacement and disabled catalog entries cannot borrow a stale approval.

The native generation retains its original CSPRNG token and command. Compatible
manual/warm retries reuse its current exact signed authorization; conflicting
provider/model/profile/path/epoch retries require a new generation. A warm or
uncertain child keeps its shared device/account/provider/instance/directory charge
until trusted exact absence. Missing resources remain actionable configuration
errors rather than creating unsigned defaults.
