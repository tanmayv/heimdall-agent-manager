package http

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Sidebar chain order (task_18e73222abffee48): /chats?agent_instance_ids=...
// returns exactly the conversations bound to those instances (unknown ids
// skipped), whatever their place in the newest-N list.
@(test)
test_list_chats_by_agent_instance_ids :: proc(t: ^testing.T) {
	f: MQ_HTTP_Fixture
	mq_http_open(t, &f, "chats_by_instances")
	defer mq_http_base_close(f.base)
	list :: proc(f: ^MQ_HTTP_Fixture, query: string) -> Response {
		req := mq_http_req(f.base, "/api/v1/chats", "")
		req.method = "GET"
		req.query = query
		return list_chats_handler(&f.handlers, req)
	}
	both := list(&f, "agent_instance_ids=inst_other,inst_missing,inst_mq")
	testing.expect_value(t, both.status, 200)
	testing.expect_value(t, strings.count(both.body, `"conversation_id"`), 2)
	testing.expectf(t, strings.index(both.body, "chat_other") < strings.index(both.body, "chat_mq"), "the given order: %s", both.body)
	one := list(&f, "agent_instance_ids=inst_mq")
	testing.expect_value(t, strings.count(one.body, `"conversation_id"`), 1)
	testing.expect(t, strings.contains(one.body, "chat_mq") && !strings.contains(one.body, "chat_other"))
	none := list(&f, "agent_instance_ids=inst_missing")
	testing.expect_value(t, strings.count(none.body, `"conversation_id"`), 0)
	// No window: the target is the OLDEST of more conversations than the old
	// by-instance scan read (512) or a list page holds (200).
	_, saved, e := iface.content_save_conversation(&f.repo, domain.Chat_Conversation{
		conversation_id = "chat_oldest", owner_user_id = domain.User_ID(f.base.owner_user_id), agent_instance_id = "inst_oldest",
		created_at = "2020-01-01T00:00:00Z", updated_at = "2020-01-01T00:00:00Z",
	})
	testing.expect(t, saved, e.message)
	for i in 0 ..< 520 {
		_, ok, err := iface.content_save_conversation(&f.repo, domain.Chat_Conversation{
			conversation_id = fmt.tprintf("chat_fill_%03d", i), owner_user_id = domain.User_ID(f.base.owner_user_id),
			agent_instance_id = fmt.tprintf("inst_fill_%03d", i), created_at = "2026-10-23T10:00:00Z", updated_at = "2026-10-23T10:00:00Z",
		})
		if !testing.expect(t, ok, err.message) do return
	}
	oldest := list(&f, "agent_instance_ids=inst_oldest,inst_mq")
	testing.expect_value(t, strings.count(oldest.body, `"conversation_id"`), 2)
	testing.expectf(t, strings.contains(oldest.body, "chat_oldest"), "a coordinator past the newest 512 conversations is found: %s", oldest.body)
	newest := list(&f, "limit=200")
	testing.expect(t, !strings.contains(newest.body, "chat_oldest"), "it is outside the newest page, so only the filter finds it")
	// Without the filter the ordinary list is unchanged.
	all := list(&f, "limit=30")
	testing.expect_value(t, strings.count(all.body, `"conversation_id"`), 30)
}
