package taskv2

import "base:runtime"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// ---- match scope (Scale A: incremental matcher) ---------------------------------
//
// A unit of work records, per chain, what its writes can affect, so the
// matcher at its end (after_chain_change) re-matches only that instead of the
// whole chain:
//
//   - touched tasks: every appended event and every projection change a refold
//     persisted (a dependency completing makes its dependents ready);
//   - freed claims: every lease deleted or parked as waiting (its holder's
//     agent may now have capacity; a work lease frees a directory, a chain cap
//     or a workflow stage slot);
//   - instances and agents whose availability changed (instance terminal,
//     start-success, a fleet row change);
//   - full: the change can affect any task (recheck, a chain-wide change).
//
// The scope is thread-local like tl_fold_cache and owned by the outermost unit
// of work: a nested one records into its parent's, and end_uow drops it.
// Nothing is persisted. A chain the scope never heard of is matched in full
// (a configuration change that records nothing still re-evaluates everything).

Match_Scope_Chain :: struct {
	tasks:           map[domain.Task_ID]bool,
	// freed_holders: holder instance ids of freed claims and instances whose
	// availability changed; resolved to agents by the matcher.
	freed_holders:   map[string]bool,
	freed_agents:    map[string]bool,
	// freed_work_tasks: tasks of freed work claims (directory, chain cap and
	// workflow stage slots are shared across agents).
	freed_work_tasks: map[domain.Task_ID]bool,
	full:            bool,
}

Match_Scope :: struct {
	allocator: runtime.Allocator,
	chains:    map[domain.Task_Chain_ID]Match_Scope_Chain,
}

@(thread_local)
tl_match_scope: ^Match_Scope

// match_scope_begin: called by begin_uow. Returns the scope this unit of work
// owns (nil when an outer unit of work already owns one).
match_scope_begin :: proc() -> ^Match_Scope {
	if tl_match_scope != nil do return nil
	s := new(Match_Scope)
	s.allocator = context.allocator
	s.chains = make(map[domain.Task_Chain_ID]Match_Scope_Chain)
	tl_match_scope = s
	return s
}

// match_scope_reset drops a scope no open unit of work owns.
match_scope_reset :: proc() {
	if tl_match_scope != nil do match_scope_end(tl_match_scope)
}

// match_scope_end: called by end_uow with the scope it owns. A scope that
// match_scope_reset already dropped is not the thread's scope any more and
// is left alone.
match_scope_end :: proc(s: ^Match_Scope) {
	if s == nil || tl_match_scope != s do return
	tl_match_scope = nil
	for k, &c in s.chains {
		match_scope_chain_destroy(&c)
		delete(string(k), s.allocator)
	}
	delete(s.chains)
	free(s, s.allocator)
}

@(private = "file")
match_scope_chain_destroy :: proc(c: ^Match_Scope_Chain) {
	for k in c.tasks do delete(string(k), c.tasks.allocator)
	for k in c.freed_holders do delete(k, c.freed_holders.allocator)
	for k in c.freed_agents do delete(k, c.freed_agents.allocator)
	for k in c.freed_work_tasks do delete(string(k), c.freed_work_tasks.allocator)
	delete(c.tasks)
	delete(c.freed_holders)
	delete(c.freed_agents)
	delete(c.freed_work_tasks)
	c^ = {}
}

// The scope outlives request scratch allocators, so it clones what it keeps
// with the allocator it was created with.
@(private = "file")
match_scope_chain :: proc(chain_id: domain.Task_Chain_ID) -> ^Match_Scope_Chain {
	s := tl_match_scope
	if s == nil || chain_id == "" do return nil
	c, found := &s.chains[chain_id]
	if found do return c
	key := domain.Task_Chain_ID(clone_str(string(chain_id), s.allocator))
	s.chains[key] = Match_Scope_Chain{
		tasks = make(map[domain.Task_ID]bool, allocator = s.allocator),
		freed_holders = make(map[string]bool, allocator = s.allocator),
		freed_agents = make(map[string]bool, allocator = s.allocator),
		freed_work_tasks = make(map[domain.Task_ID]bool, allocator = s.allocator),
	}
	return &s.chains[key]
}

@(private = "file")
clone_str :: proc(v: string, allocator := context.allocator) -> string {
	out := make([]u8, len(v), allocator)
	copy(out, v)
	return string(out)
}

@(private = "file")
note_id :: proc(set: ^map[string]bool, id: string) {
	if id == "" || id in set^ do return
	set^[clone_str(id, set.allocator)] = true
}

@(private = "file")
note_task_id :: proc(set: ^map[domain.Task_ID]bool, id: domain.Task_ID) {
	if id == "" || id in set^ do return
	set^[domain.Task_ID(clone_str(string(id), set.allocator))] = true
}

match_scope_note_task :: proc(chain_id: domain.Task_Chain_ID, task_id: domain.Task_ID) {
	if c := match_scope_chain(chain_id); c != nil do note_task_id(&c.tasks, task_id)
}

// match_scope_note_claim_freed: a claim was deleted or parked as waiting.
match_scope_note_claim_freed :: proc(lease: domain.Task_Lease) {
	c := match_scope_chain(lease.chain_id)
	if c == nil do return
	note_task_id(&c.tasks, lease.task_id)
	note_id(&c.freed_holders, lease.holder_instance_id)
	if lease.kind == domain.LEASE_KIND_WORK do note_task_id(&c.freed_work_tasks, lease.task_id)
}

// match_scope_note_instance: an instance's availability changed (it ended,
// came up, or was stopped).
match_scope_note_instance :: proc(chain_id: domain.Task_Chain_ID, instance_id: string) {
	if c := match_scope_chain(chain_id); c != nil do note_id(&c.freed_holders, instance_id)
}

match_scope_note_agent :: proc(chain_id: domain.Task_Chain_ID, agent_id: string) {
	if c := match_scope_chain(chain_id); c != nil do note_id(&c.freed_agents, agent_id)
}

// match_scope_note_full: the next match of the chain in this unit of work
// covers every task.
match_scope_note_full :: proc(chain_id: domain.Task_Chain_ID) {
	if c := match_scope_chain(chain_id); c != nil do c.full = true
}

// Match_Scope_Take: what the chain's scope held, moved out (the scope keeps
// an empty entry, so a second match in the same unit of work sees only what
// changed after the first). Owned by the caller: release with
// match_scope_take_destroy.
Match_Scope_Take :: struct {
	known: bool, // the scope saw this chain in this unit of work
	chain: Match_Scope_Chain,
}

match_scope_take :: proc(chain_id: domain.Task_Chain_ID) -> Match_Scope_Take {
	s := tl_match_scope
	if s == nil do return {}
	c, found := &s.chains[chain_id]
	if !found do return {}
	out := Match_Scope_Take{known = true, chain = c^}
	c^ = Match_Scope_Chain{
		tasks = make(map[domain.Task_ID]bool, allocator = s.allocator),
		freed_holders = make(map[string]bool, allocator = s.allocator),
		freed_agents = make(map[string]bool, allocator = s.allocator),
		freed_work_tasks = make(map[domain.Task_ID]bool, allocator = s.allocator),
	}
	return out
}

match_scope_take_destroy :: proc(t: ^Match_Scope_Take) {
	match_scope_chain_destroy(&t.chain)
}

// delete_claim deletes a claim and records it as freed. Every claim delete in
// the engine goes through here, so the matcher sees the capacity it freed.
delete_claim :: proc(svc: ^Service, lease: domain.Task_Lease) -> (bool, domain.Domain_Error) {
	deleted, err := iface.taskchain_delete_lease(svc.repo, lease.lease_id)
	if deleted do match_scope_note_claim_freed(lease)
	return deleted, err
}
