package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import domain "odin_test:hub/domain"

// Scan only the original prompt. Replacement text is never interpreted again.
render :: proc(prompt: string, action: domain.Action, run: domain.Action_Run, joined_count: int, allocator: mem.Allocator) -> string {
	value: json.Value
	_ = json.unmarshal(transmute([]u8)run.event_params_json, &value, allocator=allocator)
	defer json.destroy_value(value, allocator=allocator)
	params, _ := value.(json.Object)
	builder: strings.Builder
	defer strings.builder_destroy(&builder)
	pos := 0
	for pos < len(prompt) {
		left := strings.index(prompt[pos:], "{{")
		if left < 0 {strings.write_string(&builder,prompt[pos:]); break}
		left += pos
		strings.write_string(&builder,prompt[pos:left])
		right := strings.index(prompt[left+2:], "}}")
		if right < 0 {strings.write_string(&builder,prompt[left:]); break}
		right += left+2
		key := strings.trim_space(prompt[left+2:right])
		replacement, known := render_value(key,action,run,joined_count,params)
		if known {strings.write_string(&builder,replacement)} else {strings.write_string(&builder,prompt[left:right+2])}
		pos=right+2
	}
	return strings.clone(strings.to_string(builder),allocator)
}

render_value :: proc(key: string, action: domain.Action, run: domain.Action_Run, joined_count: int, params: json.Object) -> (string,bool) {
	switch key {
	case "action.id": return string(action.id),true
	case "action.name": return action.name,true
	case "run.id": return run.run_id,true
	case "run.joined_count": return fmt.tprintf("%d",joined_count),true
	case "schedule.fired_at":
		v,_ := params["fired_at"].(string)
		return v,true
	case "event.type","event.id","event.chain_id","event.task_id","event.actor","event.occurred_at":
		v,_ := params[key[len("event."):]].(string)
		return v,true
	}
	if strings.has_prefix(key,"event.data.") {
		data,_ := params["data"].(json.Object)
		v,_ := data[key[len("event.data."):]].(string)
		return v,true
	}
	return "",false
}

