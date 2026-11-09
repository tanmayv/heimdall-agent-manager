package http

import "core:strings"
import jsonx "odin_test:lib/jsonx"

// Small request helpers shared by the handlers (formerly in the removed Hub
// task-chain handler file).
path_part :: proc(path: string, index: int) -> string {
	parts := strings.split(path, "/"); defer delete(parts)
	if index < 0 || index >= len(parts) do return ""
	return parts[index]
}

json_array_optional :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_array(body, key, false, allocator)
	if !ok do return ""
	return res
}

json_object_raw :: proc(body, key: string, allocator := context.allocator) -> string {
	res, ok := jsonx.extract_raw_object(body, key, false, allocator)
	if !ok do return ""
	return res
}
