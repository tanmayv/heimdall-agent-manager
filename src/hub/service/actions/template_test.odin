package actions

import "core:mem"
import "core:testing"
import domain "odin_test:hub/domain"

@(test)
test_render_table :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track,context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator=mem.tracking_allocator(&track)
	render_scenario(t)
	testing.expect_value(t,len(track.allocation_map),0)
}
render_scenario :: proc(t: ^testing.T) {
	a:=domain.Action{id="act_a",name="{{run.id}}"}
	r:=domain.Action_Run{run_id="run_a",event_params_json=`{"type":"chain.state","id":"evt_a","entity":{"kind":"chain","id":"chain_a"},"actor":"hub","occurred_at":"then","fired_at":"now","data":{"state":"completed"}}`}
	cases:=[?]struct{input,expected:string}{
		{"{{event.type}}|{{event.id}}|{{event.entity.id}}|{{event.entity.kind}}|{{event.actor}}|{{event.occurred_at}}","chain.state|evt_a|chain_a|chain|hub|then"},
		{"{{event.data.state}}|{{event.data.absent}}|{{schedule.fired_at}}","completed||now"},
		{"{{action.id}}|{{action.name}}|{{run.id}}|{{run.joined_count}}","act_a|{{run.id}}|run_a|3"},
		{"{{ event.type }}|{{ unknown }}","chain.state|{{ unknown }}"},
		{"unclosed {{event.type","unclosed {{event.type"},
		{"plain","plain"},
  {"{{event.chain_id}}|{{event.task_id}}","{{event.chain_id}}|{{event.task_id}}"},
	}
	for tc in cases {
		got:=render(tc.input,a,r,3,context.allocator)
		testing.expect_value(t,got,tc.expected)
		delete(got)
	}
	empty:=render("{{event.id}}/{{event.data.x}}",a,{},0,context.allocator)
	testing.expect_value(t,empty,"/")
	delete(empty)
}

