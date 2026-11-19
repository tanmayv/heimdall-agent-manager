package eventinbox

import "core:fmt"
import "core:strings"

// Subjects use the producer's suffix tokens (state, requirements_changed,
// etc.). Returned filters and array are caller owned. Only metadata supplied
// by the hub is permitted; never interpolate arbitrary user subject filters.
filters :: proc(owner, chain, task, role: string) -> (result: []string, ok: bool) {
 if !subject_token(owner) || !subject_token(chain) do return nil, false
 types: []string
 switch role {
 case "coordinator":
  if task != "" do return nil, false
  types = []string{"chain.state", "task.state", "task.review_requested_from_user",
   "task.blocked_on_human", "task.review_verdict", "task.merge_conflict", "chain.work_finished"}
 case "explicit":
  if task != "" do return nil, false
  types = []string{"chain.state", "task.review_requested_from_user", "task.blocked_on_human", "chain.work_finished"}
 case "worker":
  if !subject_token(task) do return nil, false
  types = []string{"task.requirements_changed"}
 case:
  return nil, false
 }
 result = make([]string, len(types))
 for typ, i in types {
  if strings.has_prefix(typ, "chain.") {
   result[i] = fmt.aprintf("ev.%s.chain.%s.%s", owner, chain, strings.trim_prefix(typ, "chain."))
  } else {
   result[i] = fmt.aprintf("ev.%s.chain.%s.task.%s.%s", owner, chain,
    task if task != "" else "*", strings.trim_prefix(typ, "task."))
  }
 }
 return result, true
}

filters_destroy :: proc(values: []string) {
 for value in values do delete(value)
 delete(values)
}

subject_token :: proc(value: string) -> bool {
 if value == "" do return false
 for c in value {
  if c <= ' ' || c == '.' || c == '*' || c == '>' || c == 127 do return false
 }
 return true
}

// This predicate is shared by pull, nudge and wake. Entity versions do not
// determine resolvable freshness: generations are scoped to a stable topic.
topic_stale :: proc(event_generation, generation, resolved_generation: i64) -> bool {
 return event_generation <= resolved_generation || event_generation < generation
}
