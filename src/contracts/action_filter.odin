package contracts

import "core:encoding/json"

// Filter trees are JSON objects: all/any arrays, not node, or field/op/value.
// An omitted filter or {} means always. Root checks are stored wrapped in all.
Action_Filter_Limits :: struct {
 max_depth: int,
 max_checks: int,
 max_nodes: int,
 max_children: int,
 max_values: int,
 max_value_bytes: int,
 max_field_bytes: int,
 max_path_segments: int,
 max_segment_bytes: int,
 max_bytes: int,
}
ACTION_FILTER_DEFAULT_LIMITS :: Action_Filter_Limits{4,16,24,16,32,256,128,4,64,4096}
Action_Filter_Test_Request :: struct { event_type: string, filter, event: json.Value }
Action_Filter_Test_Response :: struct { valid, matched: bool, nodes: string, path, reason: string }
Action_Match_Trace :: struct { rev: i64, nodes: string }
