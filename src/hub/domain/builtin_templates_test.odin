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
