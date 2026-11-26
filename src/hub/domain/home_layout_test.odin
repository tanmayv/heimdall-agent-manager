package domain

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
test_home_layout_defaults_and_canonical_reads :: proc(t: ^testing.T) {
	layout := home_layout_default()
	testing.expect_value(t, layout.version, i64(0))
	testing.expect_value(t, len(layout.widgets), 4)
	testing.expect_value(t, layout.widgets[0].id, "activity")
	testing.expect_value(t, layout.widgets[0].width, 2)
	testing.expect_value(t, layout.widgets[1].id, "chains")
	testing.expect_value(t, layout.widgets[1].width, 1)
	testing.expect_value(t, layout.widgets[2].id, "uptime")
	testing.expect_value(t, layout.widgets[2].width, 1)
	testing.expect_value(t, layout.widgets[3].id, "fleet")
	testing.expect_value(t, layout.widgets[3].width, 2)
	for widget in layout.widgets do testing.expect(t, !widget.hidden && widget.options == nil)
	encoded, _ := json.marshal(layout, allocator = context.temp_allocator)
	testing.expect(t, !strings.contains(string(encoded), "options"), "default options are absent, as in the UI")

	err: Domain_Error
	layout, err = home_layout_parse(`{"version":7,"widgets":[{"id":"retired"},{"id":"fleet","width":1,"hidden":true,"options":{"mobile_order":0,"custom":{"list":[true,"text",4]}}},{"id":"uptime","width":9,"hidden":"true"},{"id":"fleet","width":2,"hidden":false}]}`, false)
	if !testing.expect_value(t, err.code, Error_Code.None) do return
	testing.expect_value(t, len(layout.widgets), 4)
	testing.expect_value(t, layout.widgets[0].id, "fleet")
	testing.expect(t, layout.widgets[0].width == 1 && layout.widgets[0].hidden)
	order, valid := home_layout_integer(layout.widgets[0].options["mobile_order"])
	testing.expect(t, valid && order == 0)
	testing.expect_value(t, layout.widgets[1].id, "uptime")
	testing.expect(t, layout.widgets[1].width == 1 && !layout.widgets[1].hidden)
	testing.expect_value(t, layout.widgets[2].id, "activity")
	testing.expect_value(t, layout.widgets[3].id, "chains")
	encoded, _ = json.marshal(layout, allocator = context.temp_allocator)
	decoded, decode_err := json.parse_string(string(encoded), .JSON, allocator = context.temp_allocator)
	testing.expect(t, decode_err == nil)
	object := decoded.(json.Object)
	list := object["widgets"].(json.Array)[0].(json.Object)["options"].(json.Object)["custom"].(json.Object)["list"].(json.Array)
	testing.expect(t, len(list) == 3 && list[0].(bool) && list[1].(string) == "text")
	number, number_ok := home_layout_integer(list[2])
	testing.expect(t, number_ok && number == 4)
}

@(test)
test_home_layout_write_schema_rejects_invalid_fields :: proc(t: ^testing.T) {
	for payload in ([]string{
		`null`, `{}`, `{"version":0,"widgets":null}`, `{"version":-1,"widgets":[]}`,
		`{"version":0.5,"widgets":[]}`, `{"version":9007199254740992,"widgets":[]}`,
		`{"version":"0","widgets":[]}`, `{"version":0,"widgets":[],"owner_user_id":"other"}`,
		`{"version":0,"widgets":[null]}`, `{"version":0,"widgets":[{"id":"retired","width":1,"hidden":false}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":1,"hidden":false},{"id":"fleet","width":2,"hidden":true}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":0,"hidden":false}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":1.1,"hidden":false}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":0}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"extra":1}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":null}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":[]}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":{"mobile_order":-1}}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":{"mobile_order":1.5}}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":{"mobile_order":"1"}}]}`,
		`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":{"mobile_order":9007199254740992}}]}`,
	}) {
		_, err := home_layout_parse(payload, true)
		testing.expectf(t, err.code == .Validation_Failed, "reject %s", payload)
	}
	valid, err := home_layout_parse(`{"version":0,"widgets":[{"id":"uptime","width":2,"hidden":true,"options":{"mobile_order":9007199254740991}}]}`, true)
	testing.expect_value(t, err.code, Error_Code.None)
	testing.expect_value(t, len(valid.widgets), 4)
	testing.expect_value(t, valid.widgets[0].id, "uptime")
}

@(test)
test_home_layout_write_bounds :: proc(t: ^testing.T) {
	oversize := strings.repeat(" ", HOME_LAYOUT_MAX_BYTES + 1, context.temp_allocator)
	_, err := home_layout_parse(oversize, true)
	testing.expect_value(t, err.code, Error_Code.Validation_Failed)
	prefix := `{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":{"text":"`
	text := strings.repeat("a", HOME_LAYOUT_MAX_OPTIONS_BYTES, context.temp_allocator)
	_, err = home_layout_parse(strings.concatenate({prefix, text, `"}}]}`}, context.temp_allocator), true)
	testing.expect_value(t, err.code, Error_Code.Validation_Failed)
	deep := strings.concatenate({`{"version":0,"widgets":[{"id":"fleet","width":2,"hidden":false,"options":{"a":`, strings.repeat("[", 17, context.temp_allocator), "0", strings.repeat("]", 17, context.temp_allocator), `}}]}`}, context.temp_allocator)
	_, err = home_layout_parse(deep, true)
	testing.expect_value(t, err.code, Error_Code.Validation_Failed)
}
