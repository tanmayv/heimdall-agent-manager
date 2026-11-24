package testkit

import "core:fmt"
import "core:os"
import "core:strings"

// json_escape_path: a path as a JSON string body (backslashes on Windows).
json_escape_path :: proc(p: string) -> string {
	s, _ := strings.replace_all(p, `\`, `\\`, context.temp_allocator)
	return s
}

// write_instance writes <data>/instance.json owned by the current user (spec §3).
write_instance :: proc(data_root, state_root, instance_id: string) -> bool {
	body := fmt.tprintf(`{{"schema":1,"instance_id":"%s","service_name":"heimdall-bridge-test","hub_url":"http://127.0.0.1:9","profile":"test","owner":%s,"data_root":"%s","state_root":"%s","layout":1,"created_at":1795400000}}`,
		instance_id, owner_json(), json_escape_path(data_root), json_escape_path(state_root))
	return os.write_entire_file(strings.concatenate({data_root, "/instance.json"}, context.temp_allocator), transmute([]byte)body) == nil
}
