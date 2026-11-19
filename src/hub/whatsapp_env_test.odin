package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:sync"
import "core:testing"
import app "odin_test:hub/app"

whatsapp_env_test_mutex: sync.Mutex

// Environment and os.args are process-wide; both tests take this lock.
whatsapp_test_env :: proc() -> (names: [11]string, values: [11]string, present: [11]bool) {
	names = {
		"HEIMDALL_WHATSAPP_ACCESS_TOKEN",
		"HEIMDALL_WHATSAPP_ACCESS_TOKEN_FILE",
		"HEIMDALL_WHATSAPP_APP_SECRET",
		"HEIMDALL_WHATSAPP_APP_SECRET_FILE",
		"HEIMDALL_WHATSAPP_VERIFY_TOKEN",
		"HEIMDALL_WHATSAPP_VERIFY_TOKEN_FILE",
		"HEIMDALL_WHATSAPP_PHONE_NUMBER_ID",
		"HEIMDALL_WHATSAPP_PHONE_NUMBER_ID_FILE",
		"HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID",
		"HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID_FILE",
		"HEIMDALL_WHATSAPP_API_BASE",
	}
	for name, i in names {
		values[i], present[i] = os.lookup_env(name, context.allocator)
		_ = os.unset_env(name)
	}
	return
}

whatsapp_test_env_restore :: proc(names, values: [11]string, present: [11]bool) {
	for name, i in names {
		if present[i] {_ = os.set_env(name, values[i])} else {_ = os.unset_env(name)}
		delete(values[i])
	}
}

@(test)
test_apply_whatsapp_env_inline_file_and_trim :: proc(t: ^testing.T) {
	sync.mutex_lock(&whatsapp_env_test_mutex)
	defer sync.mutex_unlock(&whatsapp_env_test_mutex)
	names, values, present := whatsapp_test_env()
	defer whatsapp_test_env_restore(names, values, present)
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/heimdall-whatsapp-env-%d", tmp, os.get_pid())
	testing.expect(t, os.write_entire_file(path, "  fixture-file-value\n\t") == nil)
	defer os.remove(path)
	for i in 0 ..< 5 do _ = os.set_env(names[i * 2 + 1], path)
	config: app.Hub_Config
	apply_whatsapp_env(&config)
	testing.expect_value(t, config.whatsapp_access_token, "fixture-file-value")
	testing.expect_value(t, config.whatsapp_app_secret, "fixture-file-value")
	testing.expect_value(t, config.whatsapp_verify_token, "fixture-file-value")
	testing.expect_value(t, config.whatsapp_phone_number_id, "fixture-file-value")
	testing.expect_value(t, config.whatsapp_business_account_id, "fixture-file-value")
	delete(config.whatsapp_access_token); delete(config.whatsapp_app_secret); delete(config.whatsapp_verify_token)
	delete(config.whatsapp_phone_number_id); delete(config.whatsapp_business_account_id)
	for i in 0 ..< 5 do _ = os.set_env(names[i * 2], "fixture-inline")
	_ = os.set_env(names[10], "http://127.0.0.1:12345")
	config = {}
	apply_whatsapp_env(&config)
	testing.expect_value(t, config.whatsapp_access_token, "fixture-inline")
	testing.expect_value(t, config.whatsapp_app_secret, "fixture-inline")
	testing.expect_value(t, config.whatsapp_verify_token, "fixture-inline")
	testing.expect_value(t, config.whatsapp_phone_number_id, "fixture-inline")
	testing.expect_value(t, config.whatsapp_business_account_id, "fixture-inline")
	testing.expect_value(t, config.whatsapp_api_base, "http://127.0.0.1:12345")
	delete(config.whatsapp_access_token); delete(config.whatsapp_app_secret); delete(config.whatsapp_verify_token)
	delete(
		config.whatsapp_phone_number_id,
	); delete(config.whatsapp_business_account_id); delete(config.whatsapp_api_base)
}

@(test)
test_whatsapp_flags_override_env :: proc(t: ^testing.T) {
	sync.mutex_lock(&whatsapp_env_test_mutex)
	defer sync.mutex_unlock(&whatsapp_env_test_mutex)
	names, values, present := whatsapp_test_env()
	defer whatsapp_test_env_restore(names, values, present)
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := fmt.tprintf("%s/heimdall-whatsapp-flags-%d", tmp, os.get_pid())
	testing.expect(t, os.write_entire_file(path, " fixture-flag\n") == nil)
	defer os.remove(path)
	for name in names do _ = os.set_env(name, "fixture-env")
	previous_args := os.args
	defer os.args = previous_args
	args := []string {
		"ham-hub",
		"--whatsapp-access-token-file",
		path,
		"--whatsapp-app-secret-file",
		path,
		"--whatsapp-verify-token-file",
		path,
		"--whatsapp-phone-number-id",
		"123",
		"--whatsapp-business-account-id",
		"456",
		"--whatsapp-api-base",
		"http://127.0.0.1:23456",
	}
	os.args = args
	// parse_args also owns unrelated startup settings for the lifetime of the process.
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	saved_context := context
	defer context = saved_context
	context.allocator = virtual.arena_allocator(&scratch)
	context.temp_allocator = context.allocator
	config := app.default_config()
	parse_args(&config)
	testing.expect_value(t, config.whatsapp_access_token, "fixture-flag")
	testing.expect_value(t, config.whatsapp_app_secret, "fixture-flag")
	testing.expect_value(t, config.whatsapp_verify_token, "fixture-flag")
	testing.expect_value(t, config.whatsapp_phone_number_id, "123")
	testing.expect_value(t, config.whatsapp_business_account_id, "456")
	testing.expect_value(t, config.whatsapp_api_base, "http://127.0.0.1:23456")
}
