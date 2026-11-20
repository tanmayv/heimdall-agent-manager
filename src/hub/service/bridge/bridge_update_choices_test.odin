package bridge

import "core:fmt"
import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import httpc "odin_test:lib/httpc"

@(test)
test_update_choices_filter_exact_targets_and_keep_latest_stable_downgrade :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{
		doc = fmt.tprintf("[%s,%s,%s,%s,%s,%s,%s]",
			catalog_test_release("v0.5.70", "linux-amd64", pre = true),
			catalog_test_release("v0.5.69", "linux-amd64", pre = true, draft = true),
			catalog_test_release("v0.5.68", "termux-arm64", pre = true),
			catalog_test_release("v0.5.67", "linux-amd64", pre = true),
			catalog_test_release("v0.5.66", "linux-amd64", pre = true),
			catalog_test_release("v0.5.60", "linux-amd64"),
			catalog_test_release("v0.5.59", "linux-amd64")),
		sums = fmt.tprintf("%s  heimdall-local-linux-amd64-v0.5.60.tar.gz\n%s  heimdall-local-linux-amd64-v0.5.70.tar.gz\n", CATALOG_TEST_SHA, CATALOG_TEST_SHA),
	}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get}
	defer bridge_update_catalog_destroy(&cat)
	_, _ = bridge_catalog_refresh(&cat)
	calls := source.calls
	br := domain.Bridge{version = "0.5.67", machine_os = "linux", machine_arch = "amd64"}
	choices := resolve_bridge_update_choices(&cat, br)
	testing.expect_value(t, len(choices), 3)
	if len(choices) != 3 do return
	testing.expect_value(t, choices[0].version, "v0.5.70")
	testing.expect(t, choices[0].prerelease && !choices[0].downgrade && choices[0].artifact_available)
	testing.expect_value(t, choices[1].version, "v0.5.68")
	testing.expect(t, !choices[1].artifact_available, "a Termux bundle is never offered to Linux")
	testing.expect_value(t, choices[2].version, "v0.5.60")
	testing.expect(t, !choices[2].prerelease && choices[2].downgrade && choices[2].artifact_available)
	testing.expect(t, source.calls == calls, "GET choices performs no network calls")
	info, ok := resolve_bridge_selected_update(&cat, br, "v0.5.70")
	testing.expect(t, ok && info.artifact_available)
	testing.expect_value(t, info.latest_version, "v0.5.70")
	testing.expect(t, strings.contains(info.download_url, "/v0.5.70/"))
	testing.expect_value(t, info.sha256, CATALOG_TEST_SHA)
	for excluded in ([]string{"v0.5.69", "v0.5.67", "v0.5.66", "v0.5.59", "v999.0.0"}) {
		_, allowed := resolve_bridge_selected_update(&cat, br, excluded)
		testing.expect(t, !allowed, excluded)
	}
	source.fail_sums = true
	info, ok = resolve_bridge_selected_update(&cat, br, "v0.5.70")
	testing.expect(t, ok && !info.artifact_available, "checksum fetch failure cannot dispatch")
	source.fail_sums = false
	source.sums = "malformed digest"
	info, ok = resolve_bridge_selected_update(&cat, br, "v0.5.70")
	testing.expect(t, ok && !info.artifact_available, "malformed digest cannot dispatch")
	source.fail = true
	_, _ = bridge_catalog_refresh(&cat)
	testing.expect(t, len(resolve_bridge_update_choices(&cat, br)) == 3, "outage retains complete metadata snapshot")
}

@(test)
test_update_choices_semver_prerelease_and_current_stable :: proc(t: ^testing.T) {
	source := Catalog_Test_Source{doc = fmt.tprintf("[%s,%s,%s,%s]",
		catalog_test_release("v1.0.0-rc.2", "linux-amd64", pre = true),
		catalog_test_release("v1.0.0-rc.10", "linux-amd64", pre = true),
		catalog_test_release("v1.0.0-rc.1", "linux-amd64", pre = true),
		catalog_test_release("v1.0.0", "linux-amd64"))}
	context.user_ptr = &source
	cat := Bridge_Update_Catalog{release_get = catalog_test_get}
	defer bridge_update_catalog_destroy(&cat)
	_, _ = bridge_catalog_refresh(&cat)
	choices := resolve_bridge_update_choices(&cat, {version = "1.0.0-rc.2"})
	testing.expect_value(t, len(choices), 2)
	if len(choices) != 2 do return
	testing.expect_value(t, choices[0].version, "v1.0.0")
	testing.expect_value(t, choices[1].version, "v1.0.0-rc.10")
	testing.expect(t, !choices[0].downgrade && choices[1].prerelease)
	choices = resolve_bridge_update_choices(&cat, {version = "1.0.0"})
	testing.expect_value(t, len(choices), 1)
	testing.expect(t, !choices[0].downgrade)
}

@(thread_local) choices_page_calls: int

choices_paginated_get :: proc(req: httpc.Request) -> (string, bool, string) {
	choices_page_calls += 1
	if len(req.query) > 1 {
		return fmt.tprintf("[%s]", catalog_test_release("v0.5.1", "linux-amd64")), true, ""
	}
	doc := strings.builder_make(context.temp_allocator)
	strings.write_string(&doc, "[")
	for i in 0..<30 {
		if i > 0 do strings.write_string(&doc, ",")
		strings.write_string(&doc, catalog_test_release(fmt.tprintf("v0.6.%d", i), "linux-amd64", pre = true))
	}
	strings.write_string(&doc, "]")
	return strings.to_string(doc), true, ""
}

@(test)
test_update_choices_find_stable_beyond_first_page :: proc(t: ^testing.T) {
	choices_page_calls = 0
	memo := Bridge_Catalog_Memo{get = choices_paginated_get}
	choices, ok := bridge_catalog_fetch_choices(&memo)
	testing.expect(t, ok)
	testing.expect_value(t, choices_page_calls, 2)
	testing.expect_value(t, len(choices), 31)
	if len(choices) == 31 {
		testing.expect_value(t, choices[30].tag, "v0.5.1")
		testing.expect(t, !choices[30].prerelease)
	}
}
