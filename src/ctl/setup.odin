package main

// heimdall-setup: idempotent per-harness readiness check + wiring guidance.
//
// Task: task_18c70887b39cdf84. Implements the detect -> auth -> writability ->
// wire-guidance -> report flow from new-machine-setup-guide.md. Phase 1 focuses on the
// safely-automatable, read-only DETECTION + POSTURE REPORT: it never installs binaries,
// never fabricates/exfiltrates credentials, and never overwrites read-only managed
// (nix/home-manager symlink) config. Human-only steps (install, auth, one-time consent)
// degrade to printed guidance.
//
// Usage:
//   ham-ctl setup                 # detect+report all known harnesses (text)
//   ham-ctl setup --json          # machine-readable report
//   ham-ctl setup --harness pi    # limit to one harness

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

Setup_Harness :: struct {
	name: string,
	bin: string,            // command to detect on PATH
	config_path: string,    // provider config directory ("" when it has no default and no env override)
	config_dir_env: string, // env var the CLI reads its config directory from ("" if none)
	config_file: string,    // primary config file under config_path ("" if none): the managed-symlink check
	install_hint: string,
	auth_hint: string,
	wire_hint: string,
}

// setup_known_harnesses lists every provider in the registry (G7): its default
// binary, config directory (env override, else the home default), install and
// auth guidance. Heimdall never installs a provider (G2); the hints are printed.
setup_known_harnesses :: proc(home: string, getenv: proc(key: string) -> string) -> []Setup_Harness {
	out := make([dynamic]Setup_Harness)
	for d in contracts.provider_descriptors() {
		env_dir := getenv(d.config_dir_env) if d.config_dir_env != "" else ""
		wire := "no Heimdall extension; activity via the harness-agnostic pane detector"
		if d.extension != .None {
			wire = fmt.aprintf("ham-ctl extension install %s; hooks invoke '$HEIMDALL_CTL_BIN' extension hook %s", d.provider, d.provider)
		}
		config_path := contracts.provider_config_dir_resolve(d, "", env_dir, home, context.allocator)
		config_file := ""
		if config_path != "" && d.config_file != "" {
			config_file = strings.concatenate({strings.trim_right(config_path, "/\\"), "/", d.config_file})
		}
		// The hint never repeats the minimum version; the registry supplies it.
		install_hint := d.install_hint
		if minimum := contracts.provider_min_version(d); minimum != "" {
			install_hint = fmt.aprintf("%s %s or newer", d.install_hint, minimum)
		}
		append(&out, Setup_Harness{
			name = d.provider, bin = d.binary,
			config_path = config_path, config_file = config_file,
			config_dir_env = d.config_dir_env,
			install_hint = install_hint, auth_hint = d.auth_guidance, wire_hint = wire,
		})
	}
	return out[:]
}

@(private = "file")
setup_getenv :: proc(key: string) -> string {
	return os.get_env_alloc(key, context.allocator)
}

setup_path_exists :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" do return false
	fi, err := os.stat(path, context.allocator)
	if err == nil { os.file_info_delete(fi, context.allocator) }
	return err == nil
}

// setup_bin_on_path resolves a bare command name against $PATH entries.
setup_bin_on_path :: proc(bin: string) -> (string, bool) {
	if strings.trim_space(bin) == "" do return "", false
	path_env := os.get_env_alloc("PATH", context.allocator)
	if path_env == "" do return "", false
	dirs := strings.split(path_env, ":")
	defer delete(dirs)
	for d in dirs {
		if d == "" do continue
		candidate := strings.concatenate({strings.trim_right(d, "/"), "/", bin})
		if setup_path_exists(candidate) do return candidate, true
	}
	return "", false
}

// setup_is_symlink reports whether a path is a symlink (managed/read-only config
// signal on nix/home-manager machines -> use an overlay, never overwrite).
setup_is_symlink :: proc(path: string) -> bool {
	if !setup_path_exists(path) do return false
	// A successful readlink means path is a symlink. On managed (nix/home-manager)
	// machines these typically resolve into /nix/store and are read-only.
	link, err := os.read_link(path, context.allocator)
	if err != nil do return false
	is_link := link != ""
	delete(link)
	return is_link
}

// setup_config_managed reports whether a harness's config is a read-only managed
// symlink (Nix/home-manager): its primary config file, or the whole directory.
// Such config needs a writable overlay; setup never overwrites it.
setup_config_managed :: proc(h: Setup_Harness) -> bool {
	return setup_is_symlink(h.config_file) || setup_is_symlink(h.config_path)
}

// setup_report_json is the `setup --json` report for harnesses (only: one name).
setup_report_json :: proc(harnesses: []Setup_Harness, only: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{\"harnesses\":[")
	first := true
	for h in harnesses {
		if only != "" && h.name != only do continue
		bin_path, present := setup_bin_on_path(h.bin)
		cfg_present := setup_path_exists(h.config_path)
		cfg_symlink := setup_config_managed(h)
		if !first do strings.write_string(&b, ",")
		first = false
		strings.write_string(&b, "{\"name\":\""); json_write_string(&b, h.name)
		strings.write_string(&b, "\",\"bin\":\""); json_write_string(&b, h.bin)
		strings.write_string(&b, "\",\"installed\":"); strings.write_string(&b, "true" if present else "false")
		strings.write_string(&b, ",\"bin_path\":\""); json_write_string(&b, bin_path)
		strings.write_string(&b, "\",\"config_path\":\""); json_write_string(&b, h.config_path)
		strings.write_string(&b, "\",\"config_file\":\""); json_write_string(&b, h.config_file)
		strings.write_string(&b, "\",\"config_dir_env\":\""); json_write_string(&b, h.config_dir_env)
		strings.write_string(&b, "\",\"config_present\":"); strings.write_string(&b, "true" if cfg_present else "false")
		strings.write_string(&b, ",\"config_readonly_symlink\":"); strings.write_string(&b, "true" if cfg_symlink else "false")
		strings.write_string(&b, ",\"needs_overlay\":"); strings.write_string(&b, "true" if cfg_symlink else "false")
		strings.write_string(&b, ",\"install_hint\":\""); json_write_string(&b, h.install_hint)
		strings.write_string(&b, "\",\"auth_hint\":\""); json_write_string(&b, h.auth_hint)
		strings.write_string(&b, "\"}")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

ctl_setup_command :: proc(args: []string) {
	as_json := has_flag(args, "--json")
	only := option_value(args, "--harness", "")
	harnesses := setup_known_harnesses(os.get_env_alloc("HOME", context.allocator), setup_getenv)

	if as_json {
		fmt.println(setup_report_json(harnesses, only))
		return
	}

	fmt.println("Ninjy harness setup report (detect-only; nothing installed or modified)")
	fmt.println("=========================================================================")
	for h in harnesses {
		if only != "" && h.name != only do continue
		bin_path, present := setup_bin_on_path(h.bin)
		cfg_present := setup_path_exists(h.config_path)
		cfg_symlink := setup_config_managed(h)
		fmt.printf("\n[%s]\n", h.name)
		if present {
			fmt.printf("  installed:   yes (%s)\n", bin_path)
		} else {
			fmt.printf("  installed:   NO  -> %s\n", h.install_hint)
		}
		config := h.config_path if h.config_path != "" else "(none by default)"
		if h.config_dir_env != "" do config = fmt.tprintf("%s  [%s]", config, h.config_dir_env)
		fmt.printf("  config:      %s%s\n", config, cfg_present || h.config_path == "" ? "" : "  (absent)")
		if h.config_file != "" do fmt.printf("  config file: %s%s\n", h.config_file, setup_path_exists(h.config_file) ? "" : "  (absent)")
		if cfg_symlink {
			fmt.println("  managed:     read-only symlink -> wrapper must use a writable OVERLAY, not overwrite")
		}
		fmt.printf("  auth:        %s\n", h.auth_hint)
		fmt.printf("  wiring:      %s\n", h.wire_hint)
	}
	fmt.println("\nHuman-only steps: install binary, authenticate, one-time permission/trust consent.")
	fmt.println("Automatable by the wrapper: activity + permission hook wiring (overlay where config is read-only).")
}
