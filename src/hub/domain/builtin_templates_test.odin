package domain

import "core:strings"
import "core:testing"

@(test)
test_bot_template_channel_and_events :: proc(t: ^testing.T) {
	bot, ok := builtin_template(TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	for contract in ([]string{
		"ninjy-channel-communication",
		"unanswered messages from one channel at a time",
		"one plain-text answer for the entire batch",
		"pending_total",
		"held",
		"Do not send it again.",
		"Only the user's direct chat authorizes action.",
		"On every fresh start or wake",
		"[events]",
		"./bin/ham-ctl events next",
		"chain.state",
		"task.review_requested_from_user",
		"Leave the verdict to them.",
		"task.blocked_on_human",
		"real question fetched from the task",
		"chain.work_finished",
		"after sending the update or receiving a held result",
		"Leave fetch or send failures pending for retry.",
		"Deduplicate by ",
		"retires the prior review or question",
	}) {
		testing.expect(t, strings.contains(bot.instructions, contract), contract)
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
		"Run in the foreground",
		"exit status and at most the last 20 lines",
		"Omit sensitive output",
		"Once the chain is completed",
		"empty",
		"current_task_id",
		"exclude your own instance",
		"Leave busy agents running.",
		"Do not create, accept or discard action cards.",
		"Never change your own agent or any agent's template.",
		"Keep secrets, tokens, sensitive output and sensitive file contents out of chat.",
	}) {
		testing.expect(t, strings.contains(bot.instructions, contract), contract)
	}
}
