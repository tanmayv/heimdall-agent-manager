package sqlite

import "core:sync"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import lockorder "odin_test:lib/lockorder"
import metrics "odin_test:lib/metrics"
import dbt "odin_test:hub/platform/dbtelemetry"

// tx_mutex serialises every unit of work in the process (Task System v2 §2.1).
//
// The hub has ONE sqlite connection shared by every request thread
// (server.odin is thread-per-connection) and no application-level lock around
// it. Two threads issuing BEGIN on that one handle do not get two transactions:
// the second BEGIN fails ("cannot start a transaction within a transaction") or,
// worse, an unrelated thread's autocommit writes land inside the open
// transaction and are rolled back with it. So `begin` takes this mutex and
// `commit`/`rollback` release it: at any moment there is exactly one unit of
// work in the process, which is also what makes "the matcher runs inside the
// verb's transaction" and "two matcher runs on one chain are impossible" true
// without any further coordination.
//
// INVARIANT FOR CALLERS: never hold a unit of work across network I/O. Bridge
// wakes and user-event publishes happen AFTER commit; a verb that did otherwise
// would stall every other write in the hub behind a socket.
//
// LOCK ORDER (review B1): tx_mutex → Bridge_Runtime_Connection.state_mutex is
// the single allowed order (a unit of work may reserve runtime capacity via
// bridge_runtime_instance_apply). Code holding a state_mutex must never begin a
// unit of work; it returns facts (terminal/activity) and the caller acts after
// the unlock. lockorder.assert_tx_mutex_allowed enforces it at begin.
//
// SQLite connection mutexes are held only for statements / short repository
// operations, NEVER across an outer UoW. Runtime persistence releases state_mutex
// before DB work. A UoW may reserve state, never take state_mutex under db_mutex.
// Bot multi-statement transactions join the tx_mutex gate before db_mutex via
// tx_repository_enter/leave; no repository gate may be entered under state_mutex.
//
// NESTING: a thread that already owns the unit of work and begins another one
// (card accept → change_chain_status → engine chain_closed) gets a SAVEPOINT
// nested inside the outer transaction instead of a self-deadlock. The mutex is
// taken at depth 0 and released when depth returns to 0; a nested commit is
// RELEASE, a nested rollback is ROLLBACK TO + RELEASE. A nested UoW's
// post-commit effects are registered with unit_of_work_after_commit and run by
// the outermost COMMIT after the mutex is released, so the no-I/O rule holds
// for nested units too (review S7).
@(private = "file")
tx_mutex: sync.Mutex
// tx_owner_thread / tx_depth are read before the mutex is taken (to detect
// same-thread nesting), so they are accessed atomically (review S7).
@(private = "file")
tx_owner_thread: int
@(private = "file")
tx_depth: int
@(private = "file")
tx_outbox_conn: ^Conn
// Shallowest savepoint with an outbox append; -1 means no surviving append.
@(private = "file")
tx_outbox_mark_depth: int = -1
@(private = "file")
tx_inbox_mark_depth: int = -1
// tx_after_commit: hooks registered by nested units of work, run by the
// outermost commit AFTER the mutex is released. Only the owner thread touches
// it while the transaction is open. `depth` lets a nested rollback drop the
// hooks its savepoint registered.
@(private = "file")
tx_after_commit: [dynamic]Pending_After_Commit
// DB telemetry (owner-written): lock token, outer BEGIN start, and the acquire
// tick for heimdall_db_uow_oldest_hold_seconds (atomic; 0 = no open UoW).
@(private = "file")
tx_lock_token: dbt.Lock_Token
@(private = "file")
tx_started: time.Tick
@(private = "file")
tx_acquired_nsec: i64
// Opt-in lock profile acquire time (owner-written; 0 while the profile is off).
@(private = "file")
tx_profile_acquired: i64

@(private = "file")
Pending_After_Commit :: struct {
	depth: int,
	hook:  iface.After_Commit_Hook,
}

SQLite_Unit_Of_Work_Factory :: struct {
	bots: Bot_Repo_SQLite,
	conn: ^Conn,
	repos: ^iface.Repositories,
}

SQLite_Unit_Of_Work_Context :: struct {
	conn: ^Conn,
	repos: ^iface.Repositories,
	closed: bool,
	// depth 0 = the outer BEGIN/COMMIT that owns the mutex; >0 = SAVEPOINT.
	depth: int,
}

new_unit_of_work_factory :: proc(factory: ^SQLite_Unit_Of_Work_Factory, conn: ^Conn, repos: ^iface.Repositories) -> iface.Unit_Of_Work_Factory {
	factory.conn = conn
	factory.repos = repos
	if repos != nil && repos.bots.bot_get_by_instance == nil do repos.bots = new_bot_repository(&factory.bots, conn)
	return iface.Unit_Of_Work_Factory{ctx = rawptr(factory), begin = sqlite_uow_begin}
}

sqlite_uow_begin :: proc(ctx: rawptr) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
	factory := (^SQLite_Unit_Of_Work_Factory)(ctx)
	if factory == nil || factory.conn == nil || factory.conn.db == nil {
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "sqlite unit of work factory is not open")
	}
	me := sync.current_thread_id()
	if sync.atomic_load(&tx_depth) > 0 && sync.atomic_load(&tx_owner_thread) == me {
		// Nested: this thread already owns the transaction.
		depth := sync.atomic_load(&tx_depth)
		sp := savepoint_name(depth)
		if !exec(factory.conn, sp.begin) do return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to open nested savepoint")
		uow_ctx := new(SQLite_Unit_Of_Work_Context)
		uow_ctx.conn = factory.conn
		uow_ctx.repos = factory.repos
		uow_ctx.depth = depth
		sync.atomic_store(&tx_depth, depth + 1)
		if dbt.enabled() do metrics.counter_inc(sqlite_tm.uow_nested)
		return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos, nested = true, after_commit = sqlite_uow_after_commit}, true, domain.Domain_Error{}
	}
	lockorder.assert_tx_mutex_allowed()
	tx_lock(factory.conn)
	if !exec(factory.conn, "BEGIN;") {
		tx_unlock(factory.conn, .Begin_Failed)
		return iface.Unit_Of_Work{}, false, domain.domain_error(.Internal_Error, "failed to begin transaction")
	}
	sync.atomic_store(&tx_owner_thread, me)
	tx_outbox_mark_depth = -1
 tx_inbox_mark_depth = -1
	tx_outbox_conn = factory.conn
	sync.atomic_store(&tx_depth, 1)
	uow_ctx := new(SQLite_Unit_Of_Work_Context)
	uow_ctx.conn = factory.conn
	uow_ctx.repos = factory.repos
	uow_ctx.depth = 0
	return iface.Unit_Of_Work{ctx = rawptr(uow_ctx), commit = sqlite_uow_commit, rollback = sqlite_uow_rollback, repos = factory.repos, after_commit = sqlite_uow_after_commit}, true, domain.Domain_Error{}
}

// sqlite_uow_after_commit queues a hook on the transaction this unit of work
// belongs to; the outermost commit runs it after releasing the mutex.
sqlite_uow_after_commit :: proc(ctx: rawptr, hook: iface.After_Commit_Hook) -> bool {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return false
	if tx_after_commit == nil do tx_after_commit = make([dynamic]Pending_After_Commit)
	append(&tx_after_commit, Pending_After_Commit{depth = uow_ctx.depth, hook = hook})
	return true
}

// drop_after_commit_from removes hooks registered at `depth` or deeper (a
// rolled-back savepoint takes its hooks with it).
@(private = "file")
drop_after_commit_from :: proc(depth: int) {
	if tx_outbox_mark_depth >= depth do tx_outbox_mark_depth = -1
 if tx_inbox_mark_depth >= depth do tx_inbox_mark_depth = -1
	for i := 0; i < len(tx_after_commit); i += 1 {
		if tx_after_commit[i].depth >= depth {
			hook:=tx_after_commit[i].hook
			if hook.discard!=nil do hook.discard(hook.ctx)
			ordered_remove(&tx_after_commit, i)
			i -= 1
		}
	}
}

Savepoint_SQL :: struct { begin, release, rollback: string }

@(private = "file")
savepoint_name :: proc(depth: int) -> Savepoint_SQL {
	switch depth {
	case 1: return {"SAVEPOINT uow_1;", "RELEASE uow_1;", "ROLLBACK TO uow_1; RELEASE uow_1;"}
	case 2: return {"SAVEPOINT uow_2;", "RELEASE uow_2;", "ROLLBACK TO uow_2; RELEASE uow_2;"}
	case 3: return {"SAVEPOINT uow_3;", "RELEASE uow_3;", "ROLLBACK TO uow_3; RELEASE uow_3;"}
	}
	return {"SAVEPOINT uow_n;", "RELEASE uow_n;", "ROLLBACK TO uow_n; RELEASE uow_n;"}
}

sqlite_uow_commit :: proc(ctx: rawptr) -> (bool, domain.Domain_Error) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return false, domain.domain_error(.Internal_Error, "transaction is closed")
	uow_ctx.closed = true
	if uow_ctx.depth > 0 {
		sp := savepoint_name(uow_ctx.depth)
		ok := exec(uow_ctx.conn, sp.release)
		if !ok {
			exec(uow_ctx.conn, sp.rollback)
			drop_after_commit_from(uow_ctx.depth)
		}
		if ok && tx_outbox_mark_depth >= uow_ctx.depth do tx_outbox_mark_depth = uow_ctx.depth - 1
  if ok && tx_inbox_mark_depth >= uow_ctx.depth do tx_inbox_mark_depth = uow_ctx.depth - 1
		sync.atomic_store(&tx_depth, uow_ctx.depth)
		free(uow_ctx)
		if !ok do return false, domain.domain_error(.Internal_Error, "failed to release nested savepoint")
		return true, domain.Domain_Error{}
	}
	uow_ctx_conn := uow_ctx.conn
	ok := exec(uow_ctx.conn, "COMMIT;")
	if !ok {
		// A failed COMMIT leaves the transaction open on the handle; roll it back
		// so the next BEGIN (on whichever thread wins the mutex) can start clean.
		exec(uow_ctx.conn, "ROLLBACK;")
		drop_after_commit_from(0)
	}
	wake_outbox := ok && tx_outbox_mark_depth >= 0
	outbox_hook, outbox_ctx := uow_ctx_conn.outbox_after_commit, uow_ctx_conn.outbox_after_commit_ctx
	tx_outbox_mark_depth = -1
 wake_inbox := ok && tx_inbox_mark_depth >= 0
 inbox_hook, inbox_ctx := uow_ctx_conn.inbox_after_commit, uow_ctx_conn.inbox_after_commit_ctx
 tx_inbox_mark_depth = -1
 free(uow_ctx)
	// Take the deferred hooks out before releasing the mutex (the next owner
	// may register its own), run them after.
	hooks := tx_after_commit
	tx_after_commit = nil
	sync.atomic_store(&tx_depth, 0)
	sync.atomic_store(&tx_owner_thread, 0)
	tx_unlock(uow_ctx_conn, .Commit if ok else .Commit_Failed)
	if wake_outbox && outbox_hook != nil do outbox_hook(outbox_ctx)
 if wake_inbox && inbox_hook != nil do inbox_hook(inbox_ctx)
	if ok {
		for h in hooks do if h.hook.run != nil do h.hook.run(h.hook.ctx)
	}
	delete(hooks)
	if !ok do return false, domain.domain_error(.Internal_Error, "failed to commit transaction")
	return true, domain.Domain_Error{}
}

sqlite_uow_rollback :: proc(ctx: rawptr) {
	uow_ctx := (^SQLite_Unit_Of_Work_Context)(ctx)
	if uow_ctx == nil || uow_ctx.closed do return
	uow_ctx.closed = true
	if uow_ctx.depth > 0 {
		exec(uow_ctx.conn, savepoint_name(uow_ctx.depth).rollback)
		drop_after_commit_from(uow_ctx.depth)
		sync.atomic_store(&tx_depth, uow_ctx.depth)
		free(uow_ctx)
		return
	}
	uow_ctx_conn := uow_ctx.conn
	exec(uow_ctx.conn, "ROLLBACK;")
	drop_after_commit_from(0)
	free(uow_ctx)
	delete(tx_after_commit)
	tx_after_commit = nil
	sync.atomic_store(&tx_depth, 0)
	sync.atomic_store(&tx_owner_thread, 0)
	tx_unlock(uow_ctx_conn, .Rollback)
}

// tx_lock / tx_unlock take and release tx_mutex for the OUTER unit of work.
// With DB telemetry on they observe lock wait/hold{uow_tx} and the tx duration
// (outer BEGIN start -> COMMIT/ROLLBACK return; after-commit hooks run later,
// outside it). Lock order and semantics are exactly sync.mutex_lock/unlock.
@(private = "file")
tx_lock :: proc(conn: ^Conn) {
	profile_t0 := dbt.profile_start()
	tx_lock_token = dbt.timed_lock(&tx_mutex, .Uow_Tx)
	if profile_t0 != 0 do tx_profile_acquired = dbt.profile_acquired(.Uow_Tx, profile_t0)
	if !tx_lock_token.timed do return
	tx_started = time.tick_now()
	sync.atomic_store(&tx_acquired_nsec, tx_started._nsec)
	tl_uow_active = true
	tl_uow_wrote = false
}

@(private = "file")
tx_unlock :: proc(conn: ^Conn, outcome: Tx_Outcome) {
	token := tx_lock_token
	tx_lock_token = {}
	if tx_profile_acquired != 0 {
		dbt.profile_released(.Uow_Tx, tx_profile_acquired)
		tx_profile_acquired = 0
	}
	if token.timed {
		kind := conn_kind_of(conn.db) if conn != nil else Conn_Kind.Other
		tx_observe(kind, .Uow, tl_uow_wrote, outcome, tx_started)
		sync.atomic_store(&tx_acquired_nsec, 0)
		tl_uow_active = false
		tl_uow_wrote = false
	}
	dbt.timed_unlock(&tx_mutex, .Uow_Tx, token)
}

// uow_oldest_hold_ns is the age of the open outer unit of work (0 if none),
// read by the scrape collector.
uow_oldest_hold_ns :: proc() -> i64 {
	acquired := sync.atomic_load(&tx_acquired_nsec)
	if acquired == 0 do return 0
	age := time.tick_now()._nsec - acquired
	return age if age > 0 else 0
}

// tx_mutex_try_lock is a TEST SEAM: it reports whether the process-wide unit of
// work mutex is currently free by trying to take it (and releasing it at once on
// success). Production code must never call it.
tx_mutex_try_lock :: proc() -> bool {
	if sync.mutex_try_lock(&tx_mutex) {
		sync.mutex_unlock(&tx_mutex)
		return true
	}
	return false
}

// outbox_uow_owns prevents a shared-handle relay from observing uncommitted rows.
outbox_uow_owns :: proc(conn: ^Conn) -> bool {
	return sync.atomic_load(&tx_depth) > 0 && sync.atomic_load(&tx_owner_thread) == sync.current_thread_id() && tx_outbox_conn == conn
}

// Short repository-owned transactions/savepoints share the UoW serialization
// gate. Enter before taking db_mutex; leave after COMMIT/ROLLBACK and releasing
// db_mutex. When already inside this threads UoW, its gate is already held.
Repository_Tx_Guard :: struct {locked, entered: bool, token: dbt.Lock_Token}

// Repository entry points call other repository writers (for example identity
// provisioning saves a user). Keep their outer guard across the whole operation
// without trying to acquire the same non-recursive mutex again.
@(thread_local)
repository_tx_depth: int

tx_repository_enter :: proc() -> Repository_Tx_Guard {
	if sync.atomic_load(&tx_depth)>0 && sync.atomic_load(&tx_owner_thread)==sync.current_thread_id() do return {}
	if repository_tx_depth > 0 {
		repository_tx_depth += 1
		return {entered=true}
	}
	lockorder.assert_tx_mutex_allowed()
	token := dbt.timed_lock(&tx_mutex, .Uow_Tx)
	repository_tx_depth = 1
	return {locked=true, entered=true, token=token}
}

tx_repository_leave :: proc(guard: Repository_Tx_Guard) {
	if !guard.entered do return
	assert(repository_tx_depth > 0)
	repository_tx_depth -= 1
	if guard.locked {
		assert(repository_tx_depth == 0)
		dbt.timed_unlock(&tx_mutex, .Uow_Tx, guard.token)
	}
}

// Every append-capable transaction is a UoW (outbox_prepare enforces this).
// Repository-owned COMMIT paths cannot append rows through this repository.
outbox_mark_appended :: proc() {
	depth := sync.atomic_load(&tx_depth) - 1
	if tx_outbox_mark_depth < 0 || depth < tx_outbox_mark_depth do tx_outbox_mark_depth = depth
}

inbox_mark_changed :: proc() {
 depth := sync.atomic_load(&tx_depth)-1
 if tx_inbox_mark_depth < 0 || depth < tx_inbox_mark_depth do tx_inbox_mark_depth=depth
}
