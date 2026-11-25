package main

import "core:fmt"
import "core:os"
import httpc "odin_test:lib/httpc"

// One REST contract for user and instance-token transports. A draft file is the
// full Apply object, including its stable request_id and expected_revision.
ctl_bridge_fleet_request :: proc(verb, bridge_id, application_id: string, args: []string) -> (Ctl_Request, bool, string) {
	if bridge_id == "" do return {},false,"bridge id is required"
	switch verb {
	case "show", "defaults", "":
		return {method=.GET,path=ctl_api("bridges",bridge_id,"launch-defaults")},true,""
	case "overrides":
		return {method=.GET,path=ctl_api("bridges",bridge_id,"agent-overrides")},true,""
	case "status":
		if application_id=="" do return {},false,"application id is required"
		return {method=.GET,path=ctl_api("bridges",bridge_id,"fleet","applications",application_id)},true,""
	case "retry":
		if application_id=="" do return {},false,"application id is required"
		return {method=.POST,path=ctl_api("bridges",bridge_id,"fleet","applications",application_id,"retry"),body=ctl_empty_object_body()},true,""
	case "apply":
		value, present := ctl_read_json_file_flag(args,"--draft-file")
		if !present do return {},false,"Apply requires --draft-file with request_id, expected_revision, default_runtime and full overrides"
		defer delete(value)
		draft, valid := ctl_parse_json_document(value)
		if !valid do return {},false,"invalid Fleet draft JSON"
		return {method=.POST,path=ctl_api("bridges",bridge_id,"fleet","apply"),body=httpc.json_body(draft)},true,""
	}
	return {},false,"usage: ham-ctl bridge fleet show|defaults|overrides|apply|status|retry <bridge-id> [application-id] [--draft-file file]"
}
ctl_bridge_fleet :: proc(verb, bridge_id, application_id: string, args: []string) {
	req, ok, message := ctl_bridge_fleet_request(verb,bridge_id,application_id,args)
	if !ok {fmt.println(ctl_error_json(message));os.exit(2)}
	ctl_capability_request(req,args)
}
