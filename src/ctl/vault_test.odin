package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import cfg_lib "odin_test:lib/config"

// Serialises every test that touches AMBIENT vault state — the HEIMDALL_HOME /
// HEIMDALL_VAULT_KEY environment and the vault key file they resolve to. Those
// are process-wide, so such tests cannot run concurrently under the multi-thread
// test runner. Hold this for the whole body, and open the sandbox below inside it.
vault_test_mutex: sync.Mutex

// ── Vault test sandbox (REQ-VAULT-4) ─────────────────────────────────────────
//
// `odin test src/ctl` used to run against the OPERATOR'S REAL vault key: the key
// path is `cfg_lib.expand_home("~/.config/heimdall/vault_key")` (src/ctl/vault.odin:64),
// so a test that set-key'd or cleared it destroyed production state. It did — an
// unsandboxed run on 2026-09-28 at 14:25:06 unlinked the operator's key and
// degraded vault encryption host-wide until it was restored.
//
// `expand_home` honours HEIMDALL_HOME ahead of HOME (src/lib/config/config.odin:251-254),
// so redirecting that ONE variable relocates the entire vault path into a temp
// dir. `ctl_vault_set_key` creates the parent directory itself, so an empty temp
// dir is a sufficient sandbox with nothing to pre-seed.
//
// Every test that reaches `ctl_read_vault_key` WITHOUT passing an explicit key —
// directly, or one level down through a params builder — must open a sandbox, for
// two distinct reasons:
//   1. it can then never write outside its own temp dir, and
//   2. a test named "without_vault_key" CREATES that condition (empty temp home,
//      HEIMDALL_VAULT_KEY unset) instead of inheriting it from the host, so the
//      suite passes identically whether or not a key is configured on the machine.
// Tests that pass the key and the configured flag as explicit arguments read no
// ambient state and deliberately do NOT take the sandbox.
//
// THREAD SAFETY, stated plainly: `os.set_env` mutates the whole process, so a
// sandbox is only isolating while it is the only one open. That is exactly what
// `vault_test_mutex` guarantees — so open the sandbox INSIDE the lock and let the
// deferred close run before the unlock. The temp dir is additionally unique per
// open, so two sandboxes can never share a path even if that discipline is broken
// later. Model for the set-and-restore shape: src/manager/vault_test.odin:16-23.
Ctl_Vault_Test_Sandbox :: struct {
	dir:       string,
	prev_home: string,
	had_home:  bool,
	prev_key:  string,
	had_key:   bool,

	// REQ-VAULT-2 added a FOURTH key source: the local bridge, via agent.vault.get,
	// gated on these two variables. That makes them part of the ambient vault state
	// this sandbox exists to neutralise. Without them, a suite run from inside an
	// agent's own shell — where both ARE set — reaches the live bridge, receives a
	// real key, and encrypts where the test expects the no-key fallback. Nine
	// "without_vault_key" assertions failed exactly that way, in the same tree that
	// passed under `ham-ctl shell-cmd exec`, whose bridge-service environment has
	// neither variable set.
	prev_endpoint: string,
	had_endpoint:  bool,
	prev_token:    string,
	had_token:     bool,
}

ctl_vault_test_sandbox_counter: int

// Redirects the vault key path into a fresh temp dir and clears the ambient key
// env var. ALWAYS pair with `defer ctl_vault_test_sandbox_close(&sb)` so the
// redirect is undone on the assertion-failure path too — a leaked redirect would
// silently corrupt every sibling test that runs after it.
ctl_vault_test_sandbox_open :: proc(label: string) -> Ctl_Vault_Test_Sandbox {
	sb: Ctl_Vault_Test_Sandbox

	// pid-qualified and atomically counted: unique even across concurrent opens.
	n := sync.atomic_add(&ctl_vault_test_sandbox_counter, 1)
	sb.dir = fmt.aprintf("/tmp/heimdall-ctl-vault-test-%s-%d-%d", label, int(posix.getpid()), n)
	_ = os.make_directory_all(sb.dir)

	// Create the config dir the key file lives in, so a test that READS before it
	// writes behaves the same as one that writes first. Only ctl_vault_set_key
	// (src/ctl/vault.odin:190-192) creates this directory; the other key-file call
	// sites (vault.odin:64, :118, :219, :275) just stat and report "not configured".
	// Pre-creating it makes the sandbox independent of which call site a test hits.
	cfg_dir := fmt.aprintf("%s/.config/heimdall", sb.dir)
	defer delete(cfg_dir)
	_ = os.make_directory_all(cfg_dir)

	// Capture PRESENCE, not just value: restoring an absent variable as "" would
	// turn "unset" into "set but empty" for every sibling test that follows.
	sb.prev_home, sb.had_home = os.lookup_env("HEIMDALL_HOME", context.allocator)
	sb.prev_key, sb.had_key = os.lookup_env("HEIMDALL_VAULT_KEY", context.allocator)
	sb.prev_endpoint, sb.had_endpoint = os.lookup_env("HEIMDALL_BRIDGE_ENDPOINT", context.allocator)
	sb.prev_token, sb.had_token = os.lookup_env("HEIMDALL_AGENT_TOKEN", context.allocator)

	_ = os.set_env("HEIMDALL_HOME", sb.dir)
	os.unset_env("HEIMDALL_VAULT_KEY")

	// Source 4 needs BOTH to be usable, so clearing both is belt-and-braces; it also
	// means a test that wants the bridge source can set them itself without fighting
	// a half-cleared environment.
	os.unset_env("HEIMDALL_BRIDGE_ENDPOINT")
	os.unset_env("HEIMDALL_AGENT_TOKEN")
	return sb
}

// Restores both variables to exactly the state they were in — re-set if they were
// present, unset if they were absent — then removes the temp dir.
ctl_vault_test_sandbox_close :: proc(sb: ^Ctl_Vault_Test_Sandbox) {
	if sb.had_home {
		_ = os.set_env("HEIMDALL_HOME", sb.prev_home)
	} else {
		os.unset_env("HEIMDALL_HOME")
	}
	delete(sb.prev_home)

	if sb.had_key {
		_ = os.set_env("HEIMDALL_VAULT_KEY", sb.prev_key)
	} else {
		os.unset_env("HEIMDALL_VAULT_KEY")
	}
	delete(sb.prev_key)

	if sb.had_endpoint {
		_ = os.set_env("HEIMDALL_BRIDGE_ENDPOINT", sb.prev_endpoint)
	} else {
		os.unset_env("HEIMDALL_BRIDGE_ENDPOINT")
	}
	delete(sb.prev_endpoint)

	if sb.had_token {
		_ = os.set_env("HEIMDALL_AGENT_TOKEN", sb.prev_token)
	} else {
		os.unset_env("HEIMDALL_AGENT_TOKEN")
	}
	delete(sb.prev_token)

	_ = os.remove_all(sb.dir)
	delete(sb.dir)
}

@(test)
test_vault_hex_validation :: proc(t: ^testing.T) {
	testing.expect(t, !is_valid_hex_key(""), "empty key should fail")
	testing.expect(t, !is_valid_hex_key("abcd"), "short key should fail")
	testing.expect(t, !is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef00"), "long key should fail")
	testing.expect(t, !is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg"), "non-hex char 'g' should fail")
	testing.expect(t, is_valid_hex_key("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), "lowercase 64-char hex should pass")
	testing.expect(t, is_valid_hex_key("0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"), "uppercase 64-char hex should pass")
}

// Exercises the full set-key / read-back / clear lifecycle against a SANDBOXED
// key path. Every assertion here also ran before REQ-VAULT-4; only the path moved.
@(test)
test_vault_storage_and_lifecycle :: proc(t: ^testing.T) {
	sync.mutex_lock(&vault_test_mutex)
	defer sync.mutex_unlock(&vault_test_mutex)
	sb := ctl_vault_test_sandbox_open("lifecycle")
	defer ctl_vault_test_sandbox_close(&sb)

	test_key := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	path := cfg_lib.expand_home("~/.config/heimdall/vault_key")
	defer delete(path)

	// The sandbox is only real if the path actually landed inside it. Check that
	// BEFORE anything writes, and BAIL OUT rather than continuing: testing.expect
	// records a failure but does NOT abort the test, so on a broken redirect the
	// unlink/set-key/clear below would still run — against the operator's real key,
	// which is exactly the 14:25 incident. This guard is load-bearing, not a nicety.
	if !strings.has_prefix(path, sb.dir) {
		testing.expect(t, false, fmt.tprintf("vault key path must resolve inside the sandbox %s, got %s — refusing to run destructive steps", sb.dir, path))
		return
	}

	// Clean any pre-existing key
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	_ = posix.unlink(c_path)

	// 1. Initial status: unconfigured
	set_cmd := [?]string{"vault", "set-key", test_key}
	args_set := [?]string{"ham-ctl", "vault", "set-key", test_key}
	ctl_vault_command(set_cmd[:], args_set[:])

	// 2. Verify file exists with mode 0600
	st: posix.stat_t
	stat_res := posix.stat(c_path, &st)
	testing.expect(t, stat_res == .OK, "stat must return .OK")

	all_perms := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}
	perms_valid := (st.st_mode & all_perms) == posix.mode_t{.IRUSR, .IWUSR}
	testing.expect(t, perms_valid, "vault_key file mode must be strictly 0600")

	// Verify ctl_read_vault_key reads configured 0600 file correctly
	key_read, read_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, read_ok, "ctl_read_vault_key must read configured 0600 file")
	testing.expect_value(t, key_read, test_key)

	// Verify invalid flag does not fall through to configured file
	args_bad_flag := [?]string{"ham-ctl", "issue", "list", "--vault-key", "invalid_short_hex"}
	_, bad_flag_ok := ctl_read_vault_key(args_bad_flag[:], context.temp_allocator)
	testing.expect(t, !bad_flag_ok, "invalid --vault-key flag must not fall through to file")

	// Verify invalid HEIMDALL_VAULT_KEY env does not fall through to configured file.
	// The sandbox restores this variable, so the unset below is belt-and-braces:
	// it keeps the remaining assertions on the FILE path rather than the env path.
	_ = os.set_env("HEIMDALL_VAULT_KEY", "invalid_short_hex")
	_, bad_env_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, !bad_env_ok, "invalid HEIMDALL_VAULT_KEY env must not fall through to file")
	os.unset_env("HEIMDALL_VAULT_KEY")

	// 3. Clear key
	clear_cmd := [?]string{"vault", "clear"}
	args_clear := [?]string{"ham-ctl", "vault", "clear"}
	ctl_vault_command(clear_cmd[:], args_clear[:])

	// 4. Verify file is removed
	stat_after_clear := posix.stat(c_path, &st)
	testing.expect(t, stat_after_clear != .OK, "vault_key file must be removed after clear")

	// Verify ctl_read_vault_key returns false after clear
	_, after_clear_ok := ctl_read_vault_key(nil, context.temp_allocator)
	testing.expect(t, !after_clear_ok, "ctl_read_vault_key must return false after clear")
}
