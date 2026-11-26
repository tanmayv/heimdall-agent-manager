package agent

import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import fleet_settings "odin_test:hub/service/fleet_settings"

fleet_service :: proc(service: ^Agent_Service) -> fleet_settings.Service {
	return {bridges = service.bridges, agents = service.agents, providers = service.providers}
}

// Trusted task launches and already classified starts only. Instance kind stays
// 'agent'; manual/bot/action/test callers never enter this path.
chain_fleet_runtime :: proc(service: ^Agent_Service, owner: domain.User_ID, chain_id, bridge_id, agent_id: string, legacy: domain.Fleet_Runtime) -> (domain.Fleet_Runtime, domain.Domain_Error) {
	legacy, le := chain_legacy_runtime(service, owner, chain_id, bridge_id, agent_id, legacy)
	if le.code != .None do return {}, le
	s := fleet_service(service)
	resolved, err := fleet_settings.resolve(&s, owner, bridge_id, agent_id, legacy)
	return resolved.runtime, err
}

// Borrowed legacy candidate before shared policy resolution; no network I/O.
chain_legacy_runtime :: proc(service: ^Agent_Service, owner: domain.User_ID, chain_id, bridge_id, agent_id: string, legacy: domain.Fleet_Runtime) -> (domain.Fleet_Runtime, domain.Domain_Error) {
	legacy := legacy
	if chain_id != "" && service.taskchains != nil {
		chain, found, e := iface.taskchain_get_chain(service.taskchains, domain.Task_Chain_ID(chain_id))
		if e.code != .None do return {}, e
		if !found || chain.owner_user_id != owner do return {}, domain.domain_error(.Not_Found, "task chain not found")
		rows, err := iface.taskchain_list_fleets_by_chain(service.taskchains, chain.chain_id, owner)
		if err.code != .None do return {}, err
		defer delete(rows)
		for row in rows do if row.agent_id == agent_id {legacy = fleet_settings.legacy_runtime(row, bridge_id); break}
	}
	return legacy, {}
}
