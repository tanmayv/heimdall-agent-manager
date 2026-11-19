package bots
import "core:sync"
import contracts "odin_test:contracts"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"

bots_on_experiment_disabled :: proc(s: ^Bots_Service, owner_user_id: string) {
	if s == nil do return
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex)
	deliveries, err := iface.delivery_list_open(s.repo)
	now := platform.clock_now(s.clock)
	if err.code == .None {
		for d in deliveries do if d.owner_user_id == owner_user_id do _ = bots_abandon_locked(s, d, "experiment_disabled", now)
	}
	bot, found, e := iface.bot_get_by_owner(s.repo, owner_user_id)
	sync.mutex_unlock(&s.mutex)
	if !found || e.code != .None || bot.agent_instance_id == "" || s.agents == nil do return
	inst, exists, inst_err := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
	if exists && inst_err.code == .None && agent_service.runtime_expected_active(inst.runtime_status) {
		_, _, _ = agent_service.stop_instance(s.agents, contracts.Auth_Context{kind = .Internal_User, user_id = owner_user_id}, bot.agent_instance_id, {reason = "bot_experiment_disabled"})
	}
}
