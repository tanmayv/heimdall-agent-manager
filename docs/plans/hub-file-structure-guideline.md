# Hub File Structure Guideline

Status: Target structure for the rewritten Heimdall Hub
Companion to: `hub-bridge-user-owned-architecture-and-api.md` (implements invariants 23–27 and Section 7A)

---

## 1. Purpose

This document defines the file/package layout for the Hub and the allowed
interactions between files/packages. The goal is to make the layered design
(transport → service → repository) physically enforced by package boundaries,
so "no scattered state" and "no SQLite coupling" are structural facts, not
conventions people remember.

The current daemon is a single flat `package main` with ~85 files that all see
each other's globals. That is the anti-pattern this guideline replaces.

---

## 2. Core structural rules

These rules are what prevent spaghetti. Every file below obeys them.

1. **Directory = package = layer boundary.** In Odin a directory is a package.
   We use that: each layer/domain is its own package, and cross-package calls
   are the only way layers talk. A package cannot reach into another package's
   unexported internals.
2. **Dependencies point one direction only:**
   `transport → service → repository-interface`.
   Never the reverse. A repository never imports a service; a service never
   imports transport.
3. **The engine (SQLite) is imported by exactly one place per repository:** the
   concrete repository implementation package. Nothing else imports the DB
   driver.
4. **Services depend on repository *interfaces*, not concrete implementations.**
   Concrete repositories are injected.
5. **One composition root wires everything.** Only `main` + `app` construct
   concrete types and inject them. No other file constructs a repository, opens
   a DB, or reads global singletons.
6. **No package-level mutable globals.** State lives in structs owned by a
   service/repository and passed by pointer.
7. **Each durable resource has exactly one owning service and one owning
   repository.** All writes to that resource's tables go through them.
8. **`contracts` (wire types) and persistence row structs are different types.**
   Mapping between them happens in the repository or a mapper, never leaks a row
   struct to transport.

---

## 3. Top-level package layout

```text
src/
  hub/
    main.odin                 # entrypoint: parse args/config, call app.run()
    app/                      # composition root (the ONLY wiring place)
    transport/                # HTTP + WS: parse, authz-context, serialize
    service/                  # business logic, one sub-package per domain
    repository/               # persistence: interfaces + engine impls
    domain/                   # pure data types + enums shared across layers
    platform/                 # cross-cutting primitives (no business logic)
  dev_proxy/                  # ham-dev-proxy: local Authentik/Authelia stand-in
    main.odin                 # separate binary; NOT imported by the Hub
    proxy.odin                # strip client trusted headers, inject dev user, forward
    users.odin                # configured dev users + active-user selection
  contracts/                  # shared wire types (Hub <-> Bridge/CLI/UI)
  lib/                        # engine-neutral shared libs (existing)
```

`dev_proxy` is a standalone binary (Section 6.6 of the architecture doc). It must
not import any `hub/*` package and the Hub must not import it. It forwards HTTP
to the Hub, injecting trusted identity headers exactly like a real IdP proxy, so
the Hub runs in a single `trusted_proxy` mode in both dev and prod.

Dependency direction between top-level Hub packages:

```text
main  ->  app  ->  transport  ->  service  ->  repository(interface)
                      |              |               ^
                      v              v               |
                   contracts      domain        repository(sqlite impl)
                                                     ^
                      app injects concrete sqlite impls into services
```

`domain`, `contracts`, and `platform` are leaf packages: they import nothing
from `transport`/`service`/`repository`/`app`.

---

## 4. `hub/domain` — shared data types

Pure types only. No I/O, no DB, no HTTP, no globals, no logic beyond validation
helpers on the types themselves.

```text
hub/domain/
  ids.odin            # opaque ID types + prefixes (agt_, brg_, inst_, ...)
  user.odin           # User struct + status enum
  bridge.odin         # Bridge, BridgeCapability, BridgeEnrollment
  agent.odin          # Agent, AgentBridgeSupport
  instance.odin       # AgentInstance + runtime/startup/activity status enums
  project.odin        # Project, ProjectBridgePath
  taskchain.odin      # TaskChain, Task, TaskComment, TaskCounts + status enums
  memory.odin         # Memory + type/status enums
  chat.odin           # ChatConversation, ChatMessage + direction enum
  artifact.odin       # Artifact + kind enum
  template.odin       # Template
  errors.odin         # domain error codes (maps to API error codes)
```

- **Who imports it:** everyone (`service`, `repository`, `transport`, `app`).
- **What it imports:** only `core:*`. Never other Hub packages.
- Enums for state machines (task status, runtime_status, memory status) live
  here so both service and repository agree on the same type.

---

## 5. `hub/contracts` (or reuse `src/contracts`) — wire types

Request/response DTOs and WS event envelopes. Separate from `domain` because the
wire shape (compact list rows, expansions, envelopes) differs from durable rows.

```text
contracts/
  envelope.odin       # success/list/error envelope, meta, page
  auth.odin           # AuthContext kinds
  user_api.odin       # /me, logout
  bridge_api.odin     # bridge + enrollment request/response DTOs
  agent_api.odin      # agent + bridge-support DTOs
  instance_api.odin   # start/stop/list DTOs
  project_api.odin    # project + bridge-path DTOs
  taskchain_api.odin  # chain/task/comment DTOs
  memory_api.odin     # memory DTOs
  chat_api.odin       # conversation/message DTOs
  artifact_api.odin   # artifact DTOs
  ws_events.odin      # resource_changed event shapes
  bridge_ws.odin      # Hub<->Bridge runtime envelope (if kept here)
```

- **Who imports it:** `transport` (to parse/serialize) and `app`. Services may
  use it only for input/output DTOs they are handed; services should prefer
  `domain` types internally.
- **What it imports:** `core:*`, optionally `domain` for shared enums.

---

## 6. `hub/repository` — persistence layer

This is the **only** layer that knows SQL exists. Split into interface package
and engine implementation package(s), so swapping SQLite → Postgres is adding a
sibling impl package and changing one line in `app`.

```text
hub/repository/
  iface/                       # engine-neutral interfaces (structs of procs)
    repos.odin                 # Repositories bundle (all repo interfaces)
    user_repo.odin
    bridge_repo.odin
    agent_repo.odin
    instance_repo.odin
    project_repo.odin
    taskchain_repo.odin
    memory_repo.odin
    chat_repo.odin
    artifact_repo.odin
    template_repo.odin
    unit_of_work.odin          # transaction/UoW abstraction interface
    page.odin                  # cursor/pagination params + result types
  sqlite/                      # the ONLY package importing the sqlite driver
    conn.odin                  # open/pool, pragmas, lifecycle
    migrations.odin            # ordered migration runner
    migrations/                # *.sql files (engine-neutral SQL)
    tx.odin                    # UoW implementation
    mapper.odin                # row <-> domain struct mapping helpers
    user_repo_sqlite.odin
    bridge_repo_sqlite.odin
    agent_repo_sqlite.odin
    instance_repo_sqlite.odin
    project_repo_sqlite.odin
    taskchain_repo_sqlite.odin
    memory_repo_sqlite.odin
    chat_repo_sqlite.odin
    artifact_repo_sqlite.odin
    template_repo_sqlite.odin
  blob/                        # artifact blob store (fs now, object store later)
    blob_store.odin            # interface
    fs_blob_store.odin         # filesystem impl
```

Interaction rules:

- **`iface` imports:** `domain` only. It defines interfaces as structs of proc
  fields (Odin has no interfaces; use a vtable-style struct or explicit proc
  set) plus a `Repositories` bundle that groups all repos.
- **`sqlite` imports:** `iface`, `domain`, and `vendor:sqlite3` (or the chosen
  binding). Nothing else in the Hub imports the driver.
- Each `*_repo_sqlite.odin` implements exactly one interface and touches only
  that resource's tables. Cross-table reads for expansions are explicit repo
  methods, not ad hoc joins sprinkled elsewhere.
- **Repository methods are intent-named and engine-neutral:**
  `agent_create`, `agent_list_by_owner`, `agent_set_state`. No method leaks SQL,
  a `*sqlite3.Stmt`, or a driver error upward; driver errors map to
  `domain.Error`.
- **Transactions:** a service that needs atomic multi-repo writes gets a
  `Unit_Of_Work` from the injected UoW factory and passes it to repo methods.
  Repos never `BEGIN`/`COMMIT` on their own for multi-step service operations.

Why this makes Postgres easy: add `repository/postgres/` implementing the same
`iface`, add a config switch in `app`, done. Services/transport unchanged.

---

## 7. `hub/service` — business logic

One sub-package per domain. Services hold the state machines, ownership checks,
validation, denormalized-field maintenance, and orchestration. They are the
**single write path** for their resource.

```text
hub/service/
  auth/
    auth_service.odin      # resolve AuthContext from proxy headers / tokens
    token_service.odin     # user/bridge/instance token issue/verify (hashing)
  user/
    user_service.odin      # get/auto-provision current user
  bridge/
    bridge_service.odin    # enroll, rename, revoke, capability updates
    enrollment_service.odin
    scheduler.odin         # pick a bridge for an instance (invariant 19)
  agent/
    agent_service.odin
    bridge_support_service.odin
  instance/
    instance_service.odin  # launch/stop; owns runtime_status transitions
  project/
    project_service.odin   # owns default_path + bridge-path overrides + effective path
  taskchain/
    taskchain_service.odin # owns chain + task status transitions + counts
    comment_service.odin
  memory/
    memory_service.odin    # propose/approve/reject/archive transitions
  chat/
    chat_service.odin      # conversations, send, mark-read
  artifact/
    artifact_service.odin  # metadata + blob store orchestration
  template/
    template_service.odin
  events/
    event_bus.odin         # in-proc publish of resource_changed events
  runtime/
    bridge_gateway.odin    # send commands to a connected Bridge (via transport hook)
    command_tracker.odin   # command_id lifecycle for launch/stop/validate
```

Interaction rules:

- **A service imports:** `domain`, `repository/iface`, `contracts` (for DTO
  in/out), and `platform`. A service may import **another service** only
  downward and only when a genuine orchestration need exists (e.g.
  `instance_service` uses `project_service.effective_path` and
  `bridge/scheduler`). Keep such edges few and documented in the service's file
  header.
- **A service never imports:** `transport`, `app`, `repository/sqlite`.
- **Struct-per-service holds its dependencies** (injected repo interfaces, other
  services, event bus). No globals. Example:
  ```odin
  Agent_Service :: struct {
      repos: ^iface.Repositories,   // or just the repos it needs
      events: ^events.Event_Bus,
  }
  ```
- **State transitions are methods on the owning service.** Nobody else flips a
  task to `review_ready` or an instance to `running`. This is invariant 27 made
  physical.
- **Event emission is centralized:** after a successful mutation, the owning
  service publishes a `resource_changed` event through `events.Event_Bus`.
  Transport/WS subscribe; services never talk to sockets directly.

### 6→7 direction for the Bridge runtime edge

The Hub must send commands to a live Bridge WS. To keep direction clean:

- `service/runtime/bridge_gateway.odin` exposes an interface
  `Bridge_Command_Sink` (send launch/stop/validate to a bridge_id).
- `transport/ws/bridge_ws.odin` implements/registers the live socket side and is
  injected into the gateway by `app`. Thus the service depends on an interface,
  transport provides the concrete socket. Service still doesn't import transport.

---

## 8. `hub/transport` — HTTP + WS boundary

Parses requests, resolves `AuthContext`, calls exactly one service method,
serializes the envelope. **No SQL, no business rules, no state.**

```text
hub/transport/
  http/
    server.odin            # http listener, wiring of router (built by app)
    router.odin            # path -> handler table (registered by app)
    middleware.odin        # auth-context extraction, request_id, recover
    respond.odin           # envelope/error serialization helpers
    parse.odin             # pagination/filter/sort/expand parsing helpers
    user_handlers.odin
    bridge_handlers.odin
    agent_handlers.odin
    instance_handlers.odin
    project_handlers.odin
    taskchain_handlers.odin
    memory_handlers.odin
    chat_handlers.odin
    artifact_handlers.odin
    template_handlers.odin
    batch_handlers.odin
  ws/
    user_ws.odin           # /user-ws: subscribes to event bus, pushes invalidations
    bridge_ws.odin         # /bridge-ws: bridge token auth, runtime message loop
    ws_registry.odin       # in-memory live socket registry (ephemeral, allowed)
```

Interaction rules:

- **A handler imports:** `contracts`, its target `service` package, `transport`
  helpers, and `domain` enums for mapping. Each handler holds pointers to the
  services it needs (injected via a `Handlers` struct built in `app`).
- **A handler calls exactly one service** for the mutation. If it needs data
  from two services for a response, that is a read composition and should be
  small; prefer a service method that returns the composed DTO.
- **`ws_registry` is the one sanctioned in-memory projection.** It holds live
  sockets, is rebuilt on restart, and is never a source of truth. It implements
  `service/runtime.Bridge_Command_Sink` and the user-event push target.
- Handlers convert `domain.Error` → API error envelope in one place
  (`respond.odin`).

---

## 9. `hub/platform` — cross-cutting primitives

No business logic, no domain knowledge. Pure utilities injected where needed.

```text
hub/platform/
  clock.odin       # Clock interface + real/fake (no direct time.now in services)
  ids.odin         # ID generation (prefix + random), injectable
  log.odin         # structured logging
  config.odin      # Hub config struct + loader (reuses lib/config)
  hash.odin        # token hashing (argon2/sha) for auth token storage
  cursor.odin      # opaque cursor encode/decode
```

- **Who imports it:** any layer.
- **What it imports:** `core:*` only.
- Injecting `Clock` and `ids` keeps services deterministic and unit-testable and
  avoids hidden global time/random singletons.

---

## 10. `hub/app` — composition root

The single place that constructs concrete types and wires the graph. This is
where "no singletons + explicit DI" is realized.

```text
hub/app/
  app.odin           # run(config): build graph, start server, block
  wiring.odin        # construct: platform -> repos(sqlite) -> services -> handlers
  config_bind.odin   # map config -> component options (e.g. which engine)
```

Wiring order (top of file documents it):

```text
1. load config, build platform (clock, ids, log, hash, cursor)
2. open db (sqlite.conn), run migrations
3. construct sqlite repos -> assemble iface.Repositories
4. construct blob store
5. construct event bus
6. construct services, injecting repos + event bus + platform + peer services
7. construct ws_registry; inject as Bridge_Command_Sink into runtime gateway
8. construct handlers, injecting services
9. build router (register handlers), build ws endpoints
10. start http server + ws loops
```

- **`app` imports everything; nothing imports `app`.**
- Swapping engines is a one-line change here (step 3 chooses
  `repository/sqlite` vs `repository/postgres`).

---

## 11. Allowed-import matrix (quick reference)

| Package | May import |
|---|---|
| `domain` | `core:*` |
| `contracts` | `core:*`, `domain` |
| `platform` | `core:*` |
| `repository/iface` | `domain` |
| `repository/sqlite` | `repository/iface`, `domain`, sqlite driver |
| `repository/blob` | `domain` (+ fs/object driver in impl) |
| `service/*` | `domain`, `contracts`, `repository/iface`, `platform`, `service/*` (downward only) |
| `transport/*` | `domain`, `contracts`, `service/*`, `platform` |
| `app` | everything |
| `main` | `app`, `platform/config` |

Any import that violates this table is a design bug, not a style nit.

---

## 12. Anti-spaghetti checklist

- No file outside `repository/sqlite` imports the SQL driver.
- No package-level `var`/global holding a service, repo, connection, or map of
  live state (except `transport/ws/ws_registry`, which is ephemeral).
- No handler contains an `if status == ... { update ... }` state transition;
  that belongs to the owning service.
- No service reaches "up" into transport or "sideways" into
  `repository/sqlite`.
- Each resource's writes appear in exactly one service and one repo file.
- Cross-resource atomic writes go through a single `Unit_Of_Work`.
- Emitting a WS event is done only by publishing to `events.Event_Bus`.
- Adding Postgres touches only `repository/postgres/` + one `app` switch.
```

