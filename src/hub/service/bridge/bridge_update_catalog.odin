package bridge

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"

Bridge_Manifest_Target_Wire :: struct {
	tarball_url: string `json:"tarball_url"`,
	sha256:      string `json:"sha256"`,
}

Bridge_Update_Manifest_Wire :: struct {
	version:    string                                 `json:"version"`,
	commit_sha: string                                 `json:"commit_sha"`,
	targets:    map[string]Bridge_Manifest_Target_Wire `json:"targets"`,
}

Bridge_Update_Target :: struct {
	tarball_url: string,
	sha256:      string,
}

Bridge_Update_Info :: struct {
	update_available:  bool,
	latest_version:    string,
	latest_commit_sha: string,
	download_url:      string,
	sha256:            string,
}

Bridge_Update_Catalog :: struct {
	manifest_path:         string,
	override_version:      string,
	override_commit_sha:   string,
	override_download_url: string,
	override_sha256:       string,
}

normalize_bridge_target :: proc(os_name, arch_name: string) -> string {
	os_clean := strings.to_lower(strings.trim_space(os_name), context.temp_allocator)
	arch_clean := strings.to_lower(strings.trim_space(arch_name), context.temp_allocator)
	if arch_clean == "x86_64" do arch_clean = "amd64"
	if arch_clean == "aarch64" do arch_clean = "arm64"
	if os_clean == "" do os_clean = "linux"
	if arch_clean == "" do arch_clean = "amd64"
	return fmt.tprintf("%s-%s", os_clean, arch_clean)
}

parse_semver_part :: proc(s: string) -> (int, bool) {
	clean := strings.trim_space(s)
	if strings.has_prefix(clean, "v") || strings.has_prefix(clean, "V") {
		clean = clean[1:]
	}
	digit_len := 0
	for i := 0; i < len(clean); i += 1 {
		if clean[i] >= '0' && clean[i] <= '9' {
			digit_len += 1
		} else {
			break
		}
	}
	if digit_len == 0 do return 0, false
	val, ok := strconv.parse_int(clean[:digit_len], 10)
	return val, ok
}

compare_semver :: proc(v1, v2: string) -> int {
	v1_clean := strings.trim_space(v1)
	if strings.has_prefix(v1_clean, "v") || strings.has_prefix(v1_clean, "V") {
		v1_clean = v1_clean[1:]
	}
	v2_clean := strings.trim_space(v2)
	if strings.has_prefix(v2_clean, "v") || strings.has_prefix(v2_clean, "V") {
		v2_clean = v2_clean[1:]
	}
	if v1_clean == v2_clean do return 0

	p1 := strings.split(v1_clean, ".", context.temp_allocator)
	p2 := strings.split(v2_clean, ".", context.temp_allocator)

	for i := 0; i < 3; i += 1 {
		num1 := 0
		ok1 := false
		if i < len(p1) {
			num1, ok1 = parse_semver_part(p1[i])
		}
		num2 := 0
		ok2 := false
		if i < len(p2) {
			num2, ok2 = parse_semver_part(p2[i])
		}
		if ok1 && ok2 {
			if num1 < num2 do return -1
			if num1 > num2 do return 1
		} else if ok1 && !ok2 {
			if num1 > 0 do return 1
		} else if !ok1 && ok2 {
			if num2 > 0 do return -1
		}
	}
	return 0
}

is_bridge_update_available :: proc(bridge_version, bridge_commit, latest_version, latest_commit: string) -> bool {
	if latest_version == "" do return false
	if bridge_version == "" do return true
	cmp := compare_semver(bridge_version, latest_version)
	if cmp < 0 do return true
	if cmp > 0 do return false

	if bridge_version != latest_version do return true

	if latest_commit != "" && bridge_commit != "" && bridge_commit != latest_commit {
		return true
	}
	return false
}

resolve_bridge_update_info :: proc(catalog: ^Bridge_Update_Catalog, bridge: domain.Bridge) -> Bridge_Update_Info {
	target := normalize_bridge_target(bridge.machine_os, bridge.machine_arch)
	latest_version := contracts.APP_VERSION
	latest_commit_sha := contracts.GIT_COMMIT
	download_url := fmt.tprintf("/api/v1/updates/bundle/heimdall-local-%s.tar.gz", target)
	sha256 := ""

	manifest_path := ""
	if catalog != nil {
		if catalog.override_version != "" do latest_version = catalog.override_version
		if catalog.override_commit_sha != "" do latest_commit_sha = catalog.override_commit_sha
		if catalog.override_download_url != "" do download_url = catalog.override_download_url
		if catalog.override_sha256 != "" do sha256 = catalog.override_sha256
		manifest_path = catalog.manifest_path
	}

	env_path := os.get_env("HEIMDALL_UPDATE_MANIFEST_PATH", context.allocator)
	defer if env_path != "" do delete(env_path)
	if manifest_path == "" && env_path != "" {
		manifest_path = env_path
	}
	if manifest_path != "" && os.exists(manifest_path) {
		if data, err := os.read_entire_file(manifest_path, context.temp_allocator); err == nil {
			manifest_text := string(data)
			manifest: Bridge_Update_Manifest_Wire
			if json_err := json.unmarshal_string(manifest_text, &manifest, json.DEFAULT_SPECIFICATION, context.temp_allocator); json_err == nil {
				if manifest.version != "" && (catalog == nil || catalog.override_version == "") {
					latest_version = manifest.version
				}
				if manifest.commit_sha != "" && (catalog == nil || catalog.override_commit_sha == "") {
					latest_commit_sha = manifest.commit_sha
				}
				if manifest.targets != nil {
					if target_info, ok := manifest.targets[target]; ok {
						if target_info.tarball_url != "" && (catalog == nil || catalog.override_download_url == "") {
							download_url = target_info.tarball_url
						}
						if target_info.sha256 != "" && (catalog == nil || catalog.override_sha256 == "") {
							sha256 = target_info.sha256
						}
					}
				}
			}
		}
	}

	avail := is_bridge_update_available(bridge.version, bridge.commit_sha, latest_version, latest_commit_sha)

	return Bridge_Update_Info{
		update_available = avail,
		latest_version = latest_version,
		latest_commit_sha = latest_commit_sha,
		download_url = download_url,
		sha256 = sha256,
	}
}
