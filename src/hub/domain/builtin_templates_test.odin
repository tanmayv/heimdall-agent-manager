package domain

import "core:strings"
import "core:testing"

// The bot template keeps gates; the channel and event procedure it points to lives
// in the Ninjy skills, pinned here so a trigger never points at missing text.
NINJY_CHANNEL_SKILL :: #load("../../prompts/skills/ninjy-channel-communication/SKILL.md", string)
NINJY_OPERATIONS_SKILL :: #load("../../prompts/skills/ninjy-bot-operations/SKILL.md", string)

@(test)
test_bot_template_channel_and_events :: proc(t: ^testing.T) {
	bot, ok := builtin_template(TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	for contract in ([]string{
		"ninjy-channel-communication",
		"“Reading and answering”",
		"“Chain events”",
		"chain-events-and-claims",
		"one plain-text answer per batch",
		"Never use `chat send --to user` to answer Telegram or WhatsApp messages.",
		"held",
		"Only the user's direct chat authorizes action.",
		"On every fresh start or wake",
		"[events]",
		"./bin/ham-ctl events next",
		"Event envelopes carry IDs and enums",
		"fetch current details before sending a proactive plain-text update",
		"Leave review verdicts and answers to blocked questions to the user",
		"leave the event pending and avoid guessing",
		"chain.work_finished",
		"wait for confirmed chain completion before stopping agents",
		"Acknowledge an event only after its update was sent or held",
		"leave fetch or send failures pending for retry",
	}) {
		testing.expect(t, strings.contains(bot.instructions, contract), contract)
	}
	// Procedure moved out of the template: present under the headings bot.md names.
	for heading in ([]string{"## Reading and answering", "## Channel messages", "## Chain events"}) {
		testing.expect(t, strings.contains(NINJY_CHANNEL_SKILL, heading), heading)
	}
	for moved in ([]string{
		"unanswered messages from one channel at a time",
		"one plain-text answer for the entire batch",
		"pending_total",
		"Do not send it again.",
		"channel history --limit 20",
		"channel history --limit 50",
		"artifact download",
		"chain.state",
		"task.review_requested_from_user",
		"Leave the verdict to them.",
		"task.blocked_on_human",
		"real question fetched from the task",
		"after sending the update or receiving a held result",
		"Leave fetch or send failures pending for retry.",
		"Deduplicate by ",
		"retires the prior review or question",
		"events watch --chain <chain_id>",
	}) {
		testing.expect(t, strings.contains(NINJY_CHANNEL_SKILL, moved), moved)
	}
}

@(test)
test_bot_template_persona_is_chief_of_staff :: proc(t: ^testing.T) {
	bot, ok := builtin_template(TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(bot.persona, "chief of staff"))
	testing.expect(t, strings.contains(bot.persona, "single point of contact"))
	testing.expect(t, strings.contains(bot.persona, "own the outcome"))
}

@(test)
test_bot_template_delegation_consent_and_cleanup :: proc(t: ^testing.T) {
	bot, ok := builtin_template(TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	for contract in ([]string{
		"ninjy-bot-operations",
		"**Do it**",
		"Delegate complex work",
		"Find an existing matching chain",
		"From the user via chat:",
		"Quote the user's exact words and label everything else as your reading.",
		"**Yours**",
		"**Defer**",
		"Lead every report with the outcome",
		"“Needs you:”",
		"at most one follow-up",
		"Do not poll.",
		"corrects you the same way twice",
		"Never approve or reject memory proposals.",
		"ask before restarting it",
		"Confirm the new chain's title, project and coordinator by name and ID.",
		"A clear go-ahead in the user's next reply",
		"A refusal or unrelated reply cancels",
		"Confirm again when unclear.",
		"Confirm before archiving projects or memories.",
		"Confirm before stopping an instance that is still working.",
		"Start a server only when the user explicitly requests it.",
		"exact returned",
		"Before execution, present the exact command, path and machine.",
		"stop at the first failure",
		"A changed or retried command needs a new approval",
		"expires on withdrawal or restart",
		"Still confirm deletion, overwrites, machine stops or reboots, and force-pushes",
		"Once the chain is completed",
		"empty",
		"current_task_id",
		"exclude your own instance",
		"Leave busy agents running.",
		"Do not create, accept or discard action cards.",
		"Never change your own agent or any agent's template.",
		"Keep secrets, tokens, sensitive output and sensitive file contents out of chat.",
		"only live instances with that `chain_id`",
		"Use the context of the reply to determine what it authorizes.",
		"you don't need to ask for git commands",
		"“Run a command”",
		"“When work is done”",
	}) {
		testing.expect(t, strings.contains(bot.instructions, contract), contract)
	}
	// Recipes moved out of the template: present under the headings bot.md names.
	for moved in ([]string{
		"### Run a command",
		"I'm about to run `<command>` in <path> on <machine>.",
		"### When work is done",
		"agents instance list --live",
		"--reason chain_work_done",
		"exclude your own instance",
		"Leave busy agents running",
		"check the earlier update before sending again",
		"### Start a new chain",
		"### Message a chain's coordinator",
	}) {
		testing.expect(t, strings.contains(NINJY_OPERATIONS_SKILL, moved), moved)
	}
}
