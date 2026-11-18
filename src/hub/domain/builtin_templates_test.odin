package domain

import "core:strings"
import "core:testing"

@(test)
test_bot_template_mentions_whatsapp_and_held :: proc(t: ^testing.T) {
	bot, ok := builtin_template(TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	for sentence in ([]string{"Run `./bin/ham-ctl channel read` to get the unanswered messages of one chat app at a time; each message has a `channel` field (`telegram` or `whatsapp`).","Send one answer that covers all messages you read; it goes to the chat app those messages came from. Plain text only; links are fine.","- If `pending_total` is larger than the number of messages you read, messages from the other chat app are waiting: after answering, run `./bin/ham-ctl channel read` again and answer those too.","- If the send result says `\"held\":true`, WhatsApp's 24-hour reply window had closed. Your answer is saved and reaches the user when they next write. Do not send it again.","## Confirm first"}) do testing.expect(t, strings.contains(bot.instructions, sentence))
	testing.expect(t, !strings.contains(bot.instructions, "to get every unanswered message"))
}

@(test)
test_bot_template_confirms_new_chains_and_each_command :: proc(t: ^testing.T) {
	bot, ok := builtin_template(TEMPLATE_BOT_ID)
	testing.expect(t, ok)
	for sentence in ([]string{
		"### Start a new chain",
		"if the project is ambiguous, list up to five candidates",
		"If the user names a coordinator, use that agent.",
		"if exactly one agent has `template_id` equal to `tmpl_coordinator`, use it.",
		"If several or none match, ask which agent should coordinate",
		"Never invent a default.",
		"I am about to start chain <title> in project <name> (<id>) with coordinator <agent name> (<agent_id>). Reply yes to confirm.",
		"task-chain create --kind mixed_work --title",
		"From the user via chat: <the user's original request>",
		"Before every shell command",
		"Reply yes to confirm.",
		"anything else cancels",
		"Never batch several commands under one yes.",
		"a previous yes does not authorize another command or a retry.",
		"shell run --cmd '<command>' --cwd <path> --bridge <bridge_id>",
		"in the foreground, without `--bg`",
		"exit status and at most the last 20 lines of output",
		"Never send output that looks like a secret",
		"Do not run a shell command without its own confirmation",
	}) {
		testing.expect(t, strings.contains(bot.instructions, sentence), sentence)
	}
	testing.expect(t, !strings.contains(bot.instructions, "run commands other than `shell serve`"))
}
