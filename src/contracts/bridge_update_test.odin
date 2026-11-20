package contracts

import "core:testing"

@(test)
release_versions_order_prereleases_numerically :: proc(t: ^testing.T) {
	ordered := []string{"v0.5.9", "0.5.10-alpha", "0.5.10-alpha.2", "0.5.10-alpha.10", "0.5.10-beta", "0.5.10", "0.5.11"}
	for i in 1..<len(ordered) {
		testing.expect(t, release_version_compare(ordered[i-1], ordered[i]) < 0)
		testing.expect(t, release_version_compare(ordered[i], ordered[i-1]) > 0)
	}
	testing.expect_value(t, release_version_compare("v1.2.3+build", "1.2.3"), 0)
	testing.expect(t, release_version_valid("v1.2.3-rc.1"))
	testing.expect(t, !release_version_valid("not-a-version"))
}
