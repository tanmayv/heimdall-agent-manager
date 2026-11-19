package eventinbox

import virtual "core:mem/virtual"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Called only with an authenticated instance and its owner. This path is
// database-only: consumer provisioning is left to normal inbox reconciliation.
// A nil factory supports legacy bare services without an event inbox.
auto_watch_bot :: proc(s: ^Service, owner, instance, chain, coordinator: string) -> (result: domain.Domain_Error) {
	if s.factory == nil do return {}
	// Existing chain repository records have nested ownership; contain all
	// temporary records and errors in this synchronous operation's arena.
	caller_allocator := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return domain.domain_error(.Internal_Error, "failed to allocate bot watch scratch")
	defer virtual.arena_destroy(&arena)
	defer {result.message = strings.clone(result.message, caller_allocator)}
	context.allocator = virtual.arena_allocator(&arena)
	uow, began, err := iface.unit_of_work_begin(s.factory)
	if !began do return err
	committed := false
	defer if !committed do iface.unit_of_work_rollback(&uow)
	repo := uow.repos.event_subscriptions
	if repo.bot_agent == nil do return domain.domain_error(.Internal_Error, "bot event identity repository is not configured")
	agent, aerr := repo.bot_agent(repo.ctx, owner, instance)
	if aerr.code != .None do return aerr
	defer delete(agent)
	if agent != "" {
		if chain != "" {
			if werr := watch(s, owner, agent, chain, false); werr.code != .None do return werr
		} else if coordinator != "" {
			chains, cerr := iface.taskchain_list_chains_by_coordinator(
				&uow.repos.taskchains,
				coordinator,
				domain.User_ID(owner),
			)
			if cerr.code != .None do return cerr
			defer delete(chains)
			for row in chains {
				if werr := watch(s, owner, agent, string(row.chain_id), false); werr.code != .None do return werr
			}
		}
	}
	// Commit owns transaction cleanup even when it fails.
	committed = true
	_, err = iface.unit_of_work_commit(&uow)
	return err
}
