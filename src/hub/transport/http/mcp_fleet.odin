package http

import "core:encoding/json"
import mcp "odin_test:hub/service/mcp"
import fleet "odin_test:hub/service/fleet_application"

mcp_fleet_arguments :: proc(tool:string,value:json.Value)->(mcp.Control_Arguments,bool) {
	o,ok:=value.(json.Object);if !ok do return {},false
	a:mcp.Fleet_Arguments
	bridge,typed:=o["bridge_id"].(json.String)
	if !typed || !mcp_runtime_id(string(bridge),"brg_") do return {},false
	a.bridge_id=string(bridge)
	if tool!="fleet.apply" {
		for key,_ in o do if key!="bridge_id" && key!="application_id" do return {},false
		if tool!="fleet.read" {
			id,valid:=o["application_id"].(json.String)
			if !valid || !mcp_runtime_id(string(id),"fleet_apply_") do return {},false
			a.application_id=string(id)
		} else if _,present:=o["application_id"];present do return {},false
	} else {
		draft:=make(json.Object,context.temp_allocator)
		for key,v in o {
			if key=="bridge_id" do continue
			if key!="request_id" && key!="expected_revision" && key!="default_runtime" && key!="overrides" do return {},false
			draft[key]=v
		}
		valid := false
		a.draft, valid = fleet.parse_apply(draft)
		if !valid do return {},false
	}
	return {fleet=a},true
}
