package app

import "core:strings"
import "core:testing"

@(test)
test_preview_origin_validation :: proc(t: ^testing.T) {
	valid, ok, message := normalize_preview_origin("https://preview.example/", "https://hub.example")
	testing.expect(t, ok)
	testing.expect_value(t, valid, "https://preview.example")
	testing.expect_value(t, message, "")
	delete(valid)
	valid, ok, message = normalize_preview_origin("https://preview.example:8443", "https://hub.example")
	testing.expect(t, ok)
	testing.expect_value(t, valid, "https://preview.example:8443")
	delete(valid)
	valid, ok, message = normalize_preview_origin("https://[2001:db8::1]:8443", "https://hub.example")
	testing.expect(t, ok)
	testing.expect_value(t, valid, "https://[2001:db8::1]:8443")
	delete(valid)

	_, ok, message = normalize_preview_origin("http://preview.example", "https://hub.example")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(message, "--preview-origin"))
	_, ok, _ = normalize_preview_origin("https://preview.example/path", "https://hub.example")
	testing.expect(t, !ok)
	_, ok, _ = normalize_preview_origin("https://hub.example/", "https://hub.example")
	testing.expect(t, !ok)
	invalid_origins := []string{
		"https://",
		"https:///",
		"https://preview.example?x=1",
		"https://preview.example#x",
		"https://user@preview.example",
		"https://preview.example:",
		"https://preview.example:70000",
		"https://[not-an-ip]",
		"https://[2001:db8::1",
		"https://bad_host.example",
		"https://-preview.example",
		"https://preview-.example",
		"https://999.999.999.999",
	}
	for invalid in invalid_origins {
		_, case_ok, case_message := normalize_preview_origin(invalid, "https://hub.example")
		testing.expect(t, !case_ok)
		testing.expect(t, strings.contains(case_message, "--preview-origin"))
	}
}

@(test)
test_pairing_hub_origins_canonicalized_and_validated :: proc(t: ^testing.T) {
	list, ok, _ := parse_pairing_hub_origins(" https://Hub.Mundus.in/ , http://127.0.0.1:8081,https://hub.mundus.in:443,", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(list), 2) // the duplicate is dropped
	if len(list) == 2 {
		testing.expect_value(t, list[0], "https://hub.mundus.in:443")
		testing.expect_value(t, list[1], "http://127.0.0.1:8081")
	}
	ipv6, ok6, _ := parse_pairing_hub_origins("https://[2001:db8::1]", context.temp_allocator)
	testing.expect(t, ok6 && len(ipv6) == 1 && ipv6[0] == "https://[2001:db8::1]:443")
	empty, ok_empty, _ := parse_pairing_hub_origins("", context.temp_allocator)
	testing.expect(t, ok_empty && len(empty) == 0)
	for bad in ([]string{"hub.mundus.in", "ftp://hub.mundus.in", "https://hub.mundus.in/api", "https://hub.mundus.in:0", "https://hub.mundus.in:70000", "https://user@hub.mundus.in", "https://hub.mundus.in?x=1", "https://ok.example,https://bad example"}) {
		_, bad_ok, message := parse_pairing_hub_origins(bad, context.temp_allocator)
		testing.expect(t, !bad_ok, bad)
		testing.expect(t, strings.contains(message, "--pairing-hub-origins"), message)
	}
}

@(test)
test_preview_legacy_path_defaults_closed_and_notice :: proc(t: ^testing.T) {
	config := default_config()
	defer delete(config.forwarded_for_trusted_cidrs)
	testing.expect(t, !config.preview_legacy_path, "a dedicated preview origin must close the same-origin route by default")
	testing.expect(t, strings.has_prefix(preview_legacy_path_notice("", false), "WARNING:"))
	testing.expect(t, strings.has_prefix(preview_legacy_path_notice("https://preview.example", true), "WARNING:"))
	testing.expect(t, strings.contains(preview_legacy_path_notice("https://preview.example", false), "closed"))
}

@(test)
test_whatsapp_config_state :: proc(t: ^testing.T) {
	valid := Hub_Config {
		whatsapp_access_token        = "fixture-token",
		whatsapp_app_secret          = "fixture-secret",
		whatsapp_verify_token        = "0123456789abcdef",
		whatsapp_phone_number_id     = "123",
		whatsapp_business_account_id = "456",
	}
	configured, problem := app_whatsapp_config_state({})
	testing.expect(t, !configured)
	testing.expect_value(t, problem, "")
	configured, problem = app_whatsapp_config_state(valid)
	testing.expect(t, configured)
	testing.expect_value(t, problem, "")
	for i in 0 ..< 5 {
		config := valid
		expected := ""
		switch i {
		case 0:
			config.whatsapp_access_token = ""; expected = "HEIMDALL_WHATSAPP_ACCESS_TOKEN"
		case 1:
			config.whatsapp_app_secret = ""; expected = "HEIMDALL_WHATSAPP_APP_SECRET"
		case 2:
			config.whatsapp_verify_token = ""; expected = "HEIMDALL_WHATSAPP_VERIFY_TOKEN"
		case 3:
			config.whatsapp_phone_number_id = ""; expected = "HEIMDALL_WHATSAPP_PHONE_NUMBER_ID"
		case 4:
			config.whatsapp_business_account_id = ""; expected = "HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID"
		}
		configured, problem = app_whatsapp_config_state(config)
		testing.expect(t, !configured)
		testing.expect_value(
			t,
			problem,
			strings.concatenate({"bots: whatsapp disabled: missing ", expected}, context.temp_allocator),
		)
		delete(problem)
	}
	config := Hub_Config {
		whatsapp_access_token = "fixture-token",
	}
	configured, problem = app_whatsapp_config_state(config)
	testing.expect(t, !configured)
	testing.expect_value(
		t,
		problem,
		"bots: whatsapp disabled: missing HEIMDALL_WHATSAPP_APP_SECRET,HEIMDALL_WHATSAPP_VERIFY_TOKEN,HEIMDALL_WHATSAPP_PHONE_NUMBER_ID,HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID",
	)
	delete(problem)
	for bad in ([]string{"+123", "12a", "１２３", "123 "}) {
		config = valid; config.whatsapp_phone_number_id = bad
		configured, problem = app_whatsapp_config_state(config)
		testing.expect(t, !configured)
		testing.expect_value(
			t,
			problem,
			"bots: whatsapp disabled: phone number id and business account id must be digits",
		)
		config = valid; config.whatsapp_business_account_id = bad
		configured, problem = app_whatsapp_config_state(config)
		testing.expect(t, !configured)
		testing.expect_value(
			t,
			problem,
			"bots: whatsapp disabled: phone number id and business account id must be digits",
		)
	}
	config = valid; config.whatsapp_verify_token = "0123456789abcde"
	configured, problem = app_whatsapp_config_state(config)
	testing.expect(t, !configured)
	testing.expect_value(t, problem, "bots: whatsapp disabled: verify token must be at least 16 characters")
}

// REQ-CIS-1: hub-wide coordinator idle-stop defaults (X = 1 h, Y = 6 h) and
// the shared env/flag parser (nonnegative seconds; 0 disables).
@(test)
test_coordinator_idle_config_defaults_and_parse :: proc(t: ^testing.T) {
	config := default_config()
	defer delete(config.forwarded_for_trusted_cidrs)
	testing.expect_value(t, config.coordinator_idle_completed_seconds, 3600)
	testing.expect_value(t, config.coordinator_idle_seconds, 21600)
	for c in ([]struct{ raw: string, want: int, ok: bool }{{"0", 0, true}, {"3600", 3600, true}, {" 60 ", 60, true}, {"-1", 0, false}, {"1h", 0, false}, {"", 0, false}}) {
		got, ok := parse_idle_seconds(c.raw)
		testing.expectf(t, ok == c.ok && got == c.want, "parse_idle_seconds(%q) = %d, %v", c.raw, got, ok)
	}
}
