package bots

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Best-effort provider feedback uses the original exact address and message
// ID. Replays coalesce and a read supersedes a still-pending queue reaction.
bots_canonical_feedback_tick :: proc(s: ^Bots_Service, provider: string) {
	if !canonical_channel_enabled(s,provider) || s.repo.channel_feedback_pending==nil do return
	a := bots_adapter(s,provider)
	if a==nil || (a.react==nil && a.mark_read==nil) do return
	rows, err := s.repo.channel_feedback_pending(s.repo.ctx,provider)
	if err.code!=.None do return
	for row in rows {
		if !claim_canonical_feedback(s,row) do continue
		if row.reaction=="read" && a.mark_read!=nil {
			e := a.mark_read(a.ctx,row.chat_id,row.external_message_id)
			if e.kind!=.None do bots_feedback_error(provider,"canonical_mark_read",e)
		}
		emoji := bots_queued_reaction(provider)
		if row.reaction=="read" do emoji=BOT_READ_REACTION
		if emoji!="" && a.react!=nil {
			if e := a.react(a.ctx,row.chat_id,row.external_message_id,emoji); e.kind!=.None do bots_feedback_error(provider,"canonical_reaction",e)
		}
	}
}

@(private="file")
claim_canonical_feedback :: proc(s: ^Bots_Service, row: domain.Bot_Channel_Feedback) -> bool {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	changed, claim_err := s.repo.channel_feedback_claim(s.repo.ctx,row.input_id,row.reaction)
	if claim_err.code!=.None || !changed do return false
	state, found, state_err := iface.bot_web_activation_get(s.repo,row.owner)
	if state_err.code!=.None || !found || !state.enabled || !bots_gate_on(s.experiments,row.owner) do return false
	binding, bound, binding_err := iface.binding_get(s.repo,row.binding_id)
	if binding_err.code!=.None || !bound || binding.state!=.Active || binding.bot_id!=state.bot_id || binding.owner_user_id!=row.owner || binding.external_chat_id!=row.chat_id do return false
	grant, current, grant_err := iface.bot_channel_conversion_binding_get(s.repo,row.binding_id)
	if grant_err.code!=.None || !current || grant.activation_generation!=state.generation do return false
	entitled, entitlement_err := bots_channel_entitled(s,binding.provider,row.owner)
	if entitlement_err.code!=.None || !entitled do return false
	m, present, read_err := iface.content_get_message(s.canonical_content.content,row.input_id)
	return read_err.code==.None && present && string(m.owner_user_id)==row.owner && m.conversation_id==state.conversation_id && m.body!=""
}
