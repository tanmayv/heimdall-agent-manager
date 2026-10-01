package jsonx

import "core:strings"
import "core:testing"

@(test)
test_jsonx_escapes :: proc(t: ^testing.T) {
	json_str := `{"text":"hello \"world\" \\ \n \r \t \u0041 \ud83d\ude00"}`
	got := extract_string(json_str, "text")
	defer delete(got)
	expected := "hello \"world\" \\ \n \r \t A \U0001F600"
	testing.expect(t, got == expected, "standard and unicode escapes should match")
}

@(test)
test_jsonx_key_spoofing_immunity :: proc(t: ^testing.T) {
	// Key spoofing attempt: fake keys embedded inside string values
	json_str1 := `{"error":"fake \"kind\":\"validate_project_path_result\"","kind":"real"}`
	got1 := extract_string(json_str1, "kind")
	defer delete(got1)
	testing.expect_value(t, got1, "real")

	json_str2 := `{"data":"\"command_id\":\"spoofed\"","command_id":"real_id"}`
	got2 := extract_string(json_str2, "command_id")
	defer delete(got2)
	testing.expect_value(t, got2, "real_id")
}

@(test)
test_jsonx_top_level_precedence :: proc(t: ^testing.T) {
	json_str := `{"target":"top","payload":{"target":"nested"}}`
	got := extract_string(json_str, "target")
	defer delete(got)
	testing.expect_value(t, got, "top")
}

@(test)
test_jsonx_nested_envelope_lookup :: proc(t: ^testing.T) {
	json_str := `{"v":1,"ok":true,"payload":{"task_id":"task_123","count":42,"active":true}}`
	task_id := extract_string(json_str, "task_id")
	defer delete(task_id)
	testing.expect_value(t, task_id, "task_123")

	count := extract_int(json_str, "count")
	testing.expect_value(t, count, 42)

	active := extract_bool(json_str, "active")
	testing.expect_value(t, active, true)
}

@(test)
test_jsonx_top_level_only_mode :: proc(t: ^testing.T) {
	json_str := `{"payload":{"task_id":"task_123"}}`
	got_nested := extract_string(json_str, "task_id", fallback = "", top_level_only = false)
	defer delete(got_nested)
	testing.expect_value(t, got_nested, "task_123")

	got_top_only := extract_string(json_str, "task_id", fallback = "", top_level_only = true)
	defer delete(got_top_only)
	testing.expect_value(t, got_top_only, "")
}

@(test)
test_jsonx_malformed_json_fallback :: proc(t: ^testing.T) {
	bad_json := `{"unclosed":"string`
	got := extract_string(bad_json, "unclosed", fallback = "default")
	defer delete(got)
	testing.expect_value(t, got, "default")

	got_int := extract_int(bad_json, "key", fallback = -99)
	testing.expect_value(t, got_int, -99)

	got_bool := extract_bool(bad_json, "key", fallback = true)
	testing.expect_value(t, got_bool, true)
}

@(test)
test_jsonx_has_key :: proc(t: ^testing.T) {
	json_str := `{"present":null,"missing_not":1}`
	testing.expect(t, has_key(json_str, "present"), "null key should exist")
	testing.expect(t, has_key(json_str, "missing_not"), "key should exist")
	testing.expect(t, !has_key(json_str, "absent"), "absent key should return false")
}

@(test)
test_jsonx_string_arrays :: proc(t: ^testing.T) {
	json_str := `{"items":["one","two","three"]}`
	arr := extract_string_array(json_str, "items")
	defer {
		for s in arr do delete(s)
		delete(arr)
	}
	testing.expect_value(t, len(arr), 3)
	testing.expect_value(t, arr[0], "one")
	testing.expect_value(t, arr[1], "two")
	testing.expect_value(t, arr[2], "three")

	flat := `["alpha","beta"]`
	decoded := decode_string_array(flat)
	defer {
		for s in decoded do delete(s)
		delete(decoded)
	}
	testing.expect_value(t, len(decoded), 2)
	testing.expect_value(t, decoded[0], "alpha")
	testing.expect_value(t, decoded[1], "beta")
}

@(test)
test_jsonx_raw_object_and_array :: proc(t: ^testing.T) {
	json_str := `{"meta":{"configured":true},"tags":["a","b"]}`
	raw_obj, ok_obj := extract_raw_object(json_str, "meta")
	defer if ok_obj do delete(raw_obj)
	testing.expect(t, ok_obj, "extract_raw_object should succeed")
	testing.expect(t, strings.contains(raw_obj, `"configured":true`), "raw_obj should contain configured field")

	raw_arr, ok_arr := extract_raw_array(json_str, "tags")
	defer if ok_arr do delete(raw_arr)
	testing.expect(t, ok_arr, "extract_raw_array should succeed")
	testing.expect(t, strings.contains(raw_arr, `"a"`), "raw_arr should contain items")
}

@(test)
test_jsonx_unescape_string :: proc(t: ^testing.T) {
	unescaped, ok := unescape_string(`"test \"value\" \n"`)
	defer if ok do delete(unescaped)
	testing.expect(t, ok, "unescape_string should succeed")
	testing.expect_value(t, unescaped, "test \"value\" \n")
}

@(test)
test_jsonx_json_unescape_string_binary_and_surrogates :: proc(t: ^testing.T) {
	// Test surrogate pair \ud83d\ude00
	surrogate := json_unescape_string(`\ud83d\ude00`)
	defer delete(surrogate)
	testing.expect_value(t, surrogate, "\U0001F600")

	// Test malformed unicode escapes left alone
	bad_hex := json_unescape_string(`\u00zzTAIL`)
	defer delete(bad_hex)
	testing.expect_value(t, bad_hex, "u00zzTAIL")

	// Test raw binary byte >= 0x80 preservation
	raw_bytes := [?]byte{0x89, 'P', 'N', 'G'}
	raw_byte_str := string(raw_bytes[:])
	decoded := json_unescape_string(raw_byte_str)
	defer delete(decoded)
	testing.expect_value(t, decoded, raw_byte_str)
}

