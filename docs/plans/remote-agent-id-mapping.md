# Remote Agent-ID Mapping Plan

## Goal
Make remote agents first-class at the durable `agent_id` tier, not just one-off instance proxies.

A local remote `agent_id` maps to a remote daemon + remote durable `agent_id`. Starting/creating a local instance under that local `agent_id` creates/starts a fresh concrete instance for the remote durable `agent_id`, then persists a local remote_proxy instance mapped to the returned remote `agent_instance_id`.

## Target Model

### Local durable identity
Add remote metadata to `Agent_Id_Record`:

- `agent_kind`: `local` or `remote_proxy`
- `remote_peer_id`
- `remote_origin_daemon_id`
- `remote_agent_id`

For local agents, these fields are empty / `local`.

### Local concrete instances
Keep existing `Agent_Instance_Record` remote fields:

- `agent_kind = remote_proxy`
- `remote_peer_id`
- `remote_origin_daemon_id`
- `remote_agent_instance_id`

Invariant:

```text
local remote agent_id A -> remote durable agent_id R on peer P
local concrete instance A@s-x -> remote concrete instance R@s-y on P
```

Multiple local instances under A may map to different remote concrete instances under R.

## API Changes

### Create/bind durable remote agent id
Extend `/federation/proxies/bind` to accept:

- `local_agent_id` (optional; default derived from remote agent id + peer)
- `remote_agent_id`
- `create_remote_agent_id` bool

Behavior:

1. Validate/resolve peer.
2. If `create_remote_agent_id` is true, call remote `/agents/create` with `agent_id=remote_agent_id` if it does not exist.
3. Upsert local `Agent_Id_Record` with `agent_kind=remote_proxy` and remote mapping fields.
4. Optionally start/bind an instance if `remote_agent_instance_id` is provided or if caller requests immediate start.

### Start local remote agent id
Extend `/agents/start`:

- If request names a local remote `agent_id` with no concrete `agent_instance_id`, create a new local concrete instance id for that local id.
- Forward remote start using `agent_id=remote_agent_id` to the mapped peer.
- Parse remote returned `agent_instance_id`.
- Persist local concrete remote_proxy instance with `agent_id=local_agent_id` and `remote_agent_instance_id=returned_remote_instance_id`.
- Register status subscription and return local proxy + remote start result.

### Start existing local remote proxy instance
Keep existing behavior:

- Forward `/federation/start` using persisted `remote_agent_instance_id`.
- Do not send local provider/tier defaults unless explicit runtime overrides are provided.

### Archive/delete
Archiving a local remote `agent_id` archives local identity and local proxy instances only. It should not delete remote daemon identities or instances unless a future explicit remote-delete action is added.

## UI Changes

### Agents tab
- Add remote agent creation/binding UI.
- Allow choosing peer + remote durable `agent_id`, with option to create that remote durable id on the peer.
- Show remote durable agent ids in the same durable groups as local ids.
- Show all concrete remote instances under the local durable remote id.
- Allow start/stop/delete from detail pages and instance rows.

### Sidebar/chat
- Durable remote groups appear in the sidebar via normal agent list.
- Concrete remote instances open Agent Detail / direct chat like local agents.
- Start/stop buttons use the existing endpoints.

## Tests

Static tests:
- Agent id store persists remote mapping fields.
- `/federation/proxies/bind` can upsert a remote mapped agent id.
- `/agents/start` on a remote mapped agent id forwards remote start by `remote_agent_id` and persists returned concrete remote instance id.
- Remote provider/tier remain remote-owned.
- UI AgentPicker/Agents tab exposes remote binding path.

Runtime smoke:
- Create local remote agent id mapped to `cloudtop:coordinator`.
- Start two local instances under it; verify two local proxy instances map to remote `coordinator@s-*` instances.
- Stop/start one instance; verify routing uses its persisted remote instance id.
- Open direct chat and send a message to the proxy.
