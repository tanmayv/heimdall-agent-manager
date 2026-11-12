package http

import "core:strings"
import "core:testing"

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
	// Without the filter the ordinary list is unchanged.
	all := list(&f, "limit=30")
	testing.expect_value(t, strings.count(all.body, `"conversation_id"`), 2)
}
