package taskchain

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskv2 "odin_test:hub/service/taskv2"

// Every caller is inside the verb transaction, including completion.
save_chain_with_catalog :: proc(
	service: ^Taskchain_Service,
	chain: domain.Task_Chain,
) -> (
	domain.Task_Chain,
	bool,
	domain.Domain_Error,
) {
	if service.repo.catalog.append == nil do return iface.taskchain_save_chain(service.repo, chain)
	before, found, err := iface.taskchain_get_chain(service.repo, chain.chain_id)
	if err.code != .None && err.code != .Not_Found do return {}, false, err
	saved, ok, serr := iface.taskchain_save_chain(service.repo, chain)
	if !ok do return saved, false, serr
	if found {
		if cerr := taskv2.catalog_chain_state(service.repo, service.clock, before, saved); cerr.code != .None do return saved, false, cerr
	}
	return saved, true, {}
}
