package push

import "core:fmt"
import "core:strings"

// build_owner_attention_notification is the push for owner-chain tasks that
// newly need the user. The Hub holds no task content (titles live on the owner
// Bridge, encrypted), so the text is generic; the deck names the task.
// Heap-allocated like the other builders (free_notification_content).
build_owner_attention_notification :: proc(fresh_count: int, chain_id: string) -> Notification_Content {
	body := strings.clone("A task needs your answer or approval.") if fresh_count <= 1 else fmt.aprintf("%d tasks need your answer or approval.", fresh_count)
	return Notification_Content{
		title    = "Task needs you",
		body     = body,
		// One slot: a later snapshot replaces the earlier notification.
		tag      = strings.clone("heimdall:attention:owner-task"),
		// The chain whose task newly needs the user (its Tickets pane).
		route    = strings.concatenate({"/chains/", chain_id}) if chain_id != "" else strings.clone("/"),
		category = .Attention,
	}
}
