package main

// REQ-VAULT-HARDEN-6: Comprehensive security and regression tests for
// bridge unseal lifecycle, anti-replay, clock skew, target verification,
// tamper detection, and unencrypted self-hosted pass-through.

import "base:runtime"
import "core:crypto"
import "core:crypto/aes"
import "core:crypto/ecdh"
import "core:crypto/hkdf"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
@(private = "file")
test_isolate_disk_vault_key :: proc() -> (vault_path: string, bak_path: string, had_file: bool) {
	vault_path = bridge_expand_home("~/.config/heimdall/vault_key")
	bak_path = bridge_expand_home("~/.config/heimdall/vault_key.sec_test_bak")
	had_file = os.exists(vault_path)
	if had_file {
		_ = os.rename(vault_path, bak_path)
	}
	return
}

@(private = "file")
test_restore_disk_vault_key :: proc(vault_path, bak_path: string, had_file: bool) {
	if had_file {
		_ = os.rename(bak_path, vault_path)
	}
	delete(vault_path)
	delete(bak_path)
}

@(private = "file")
create_sec_test_envelope :: proc(
	bridge_id: string,
	bridge_pub_hex: string,
	vault_key_hex: string,
	timestamp: i64,
	nonce: string,
	tamper_aad: bool = false,
) -> string {
	client_priv: ecdh.Private_Key
	_ = ecdh.private_key_generate(&client_priv, .SECP256R1)
	defer ecdh.private_key_clear(&client_priv)

	client_pub: ecdh.Public_Key
	ecdh.public_key_set_priv(&client_pub, &client_priv)
	client_pub_bytes: [P256_POINT_SIZE]byte
	ecdh.public_key_bytes(&client_pub, client_pub_bytes[:])
	client_pub_hex_bytes, _ := hex.encode(client_pub_bytes[:], context.temp_allocator)
	client_pub_hex := string(client_pub_hex_bytes)

	bridge_pub_bytes, _ := hex.decode(transmute([]byte)bridge_pub_hex, context.temp_allocator)
	bridge_pub: ecdh.Public_Key
	_ = ecdh.public_key_set_bytes(&bridge_pub, .SECP256R1, bridge_pub_bytes)

	shared_secret: [P256_COORD_SIZE]byte
	_ = ecdh.ecdh(&client_priv, &bridge_pub, shared_secret[:])
	defer crypto.zero_explicit(&shared_secret, size_of(shared_secret))

	salt: [32]byte
	info := "heimdall-bridge-unseal-v1"
	aes_key: [32]byte
	defer crypto.zero_explicit(&aes_key, size_of(aes_key))
	hkdf.extract_and_expand(.SHA256, salt[:], shared_secret[:], transmute([]byte)info, aes_key[:])

	iv: [12]byte
	crypto.rand_bytes(iv[:])
	iv_hex_bytes, _ := hex.encode(iv[:], context.temp_allocator)

	aad := fmt.tprintf("%s:%d:%s", bridge_id, timestamp, nonce)
	if tamper_aad {
		aad = fmt.tprintf("%s:%d:%s_tampered", bridge_id, timestamp, nonce)
	}

	plaintext := transmute([]byte)vault_key_hex
	ciphertext := make([]byte, len(plaintext), context.temp_allocator)
	tag: [16]byte

	gcm: aes.Context_GCM
	aes.init_gcm(&gcm, aes_key[:])
	defer aes.reset_gcm(&gcm)
	aes.seal_gcm(&gcm, ciphertext, tag[:], iv[:], transmute([]byte)aad, plaintext)

	ct_hex_bytes, _ := hex.encode(ciphertext, context.temp_allocator)
	tag_hex_bytes, _ := hex.encode(tag[:], context.temp_allocator)

	return fmt.aprintf(
		`{{"type":"bridge_unseal","command_id":"cmd_sec_test","bridge_id":"%s","timestamp":%d,"nonce":"%s","client_public_key":"%s","iv":"%s","tag":"%s","ciphertext":"%s"}}`,
		bridge_id, timestamp, nonce, client_pub_hex, string(iv_hex_bytes), string(tag_hex_bytes), string(ct_hex_bytes),
	)
}

@(test)
test_security_unseal_transitions_locked_to_unlocked :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	vpath, bpath, had_file := test_isolate_disk_vault_key()
	defer test_restore_disk_vault_key(vpath, bpath, had_file)

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	bridge_workspace_vault_configured = true
	defer { bridge_workspace_vault_configured = false }

	bridge_vault_lock()
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Locked)
	testing.expect_value(t, bridge_vault_status_string(), "locked")

	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_sec_lifecycle_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	payload := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "nonce_sec_lifecycle_1")
	defer delete(payload)

	// Unseal call
	ok, err_msg := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms)
	testing.expect(t, ok, fmt.tprintf("unseal must succeed: %s", err_msg))

	// Status transitions from Locked to Unlocked
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Unlocked)
	testing.expect_value(t, bridge_vault_status_string(), "unlocked")

	// Decrypted key must match stored key
	stored_key, read_ok := bridge_read_vault_key()
	testing.expect(t, read_ok, "bridge_read_vault_key must succeed after unseal")
	defer if read_ok do delete(stored_key)
	testing.expect_value(t, stored_key, test_key)
}

@(test)
test_security_anti_replay_duplicate_nonce_rejected :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	vpath, bpath, had_file := test_isolate_disk_vault_key()
	defer test_restore_disk_vault_key(vpath, bpath, had_file)

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_sec_replay_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	payload := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_duplicate_nonce_xyz")
	defer delete(payload)

	// First attempt succeeds
	ok1, err1 := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms)
	testing.expect(t, ok1, fmt.tprintf("first unseal must succeed: %s", err1))

	// Replay attempt with same nonce must be rejected
	ok2, err2 := bridge_unseal_decrypt_and_verify(payload, bridge_id, now_ms + 150)
	testing.expect(t, !ok2, "replayed unseal payload with duplicate nonce must be rejected")
	testing.expect(t, strings.contains(err2, "replay rejected"), "error must cite replay rejection")
}

@(test)
test_security_clock_skew_validation_rejects_stale_and_future :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	vpath, bpath, had_file := test_isolate_disk_vault_key()
	defer test_restore_disk_vault_key(vpath, bpath, had_file)

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_sec_skew_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// 1. Expired in past (> 30s)
	past_ts := now_ms - 35_000
	payload_past := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, past_ts, "sec_skew_past_nonce")
	defer delete(payload_past)
	ok_past, err_past := bridge_unseal_decrypt_and_verify(payload_past, bridge_id, now_ms)
	testing.expect(t, !ok_past, "past clock skew > 30s must be rejected")
	testing.expect(t, strings.contains(err_past, "clock skew"), "error must cite clock skew")

	// 2. Future skew (> 30s)
	future_ts := now_ms + 35_000
	payload_future := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, future_ts, "sec_skew_future_nonce")
	defer delete(payload_future)
	ok_future, err_future := bridge_unseal_decrypt_and_verify(payload_future, bridge_id, now_ms)
	testing.expect(t, !ok_future, "future clock skew > 30s must be rejected")
	testing.expect(t, strings.contains(err_future, "clock skew"), "error must cite clock skew")

	// 3. Valid timestamp within 30s window (e.g. 5s in past)
	valid_ts := now_ms - 5_000
	payload_valid := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, valid_ts, "sec_skew_valid_nonce")
	defer delete(payload_valid)
	ok_valid, err_valid := bridge_unseal_decrypt_and_verify(payload_valid, bridge_id, now_ms)
	testing.expect(t, ok_valid, fmt.tprintf("timestamp within 30s must be accepted: %s", err_valid))
}

@(test)
test_security_wrong_destination_mismatched_bridge_id_rejected :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	vpath, bpath, had_file := test_isolate_disk_vault_key()
	defer test_restore_disk_vault_key(vpath, bpath, had_file)

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// Envelope created specifically for target bridge "brg_target_alpha"
	payload_dest := create_sec_test_envelope("brg_target_alpha", bridge_pub_hex, test_key, now_ms, "sec_dest_nonce")
	defer delete(payload_dest)

	// Delivered to mismatched bridge "brg_target_beta"
	ok, err := bridge_unseal_decrypt_and_verify(payload_dest, "brg_target_beta", now_ms)
	testing.expect(t, !ok, "payload with mismatched bridge destination must be rejected")
	testing.expect(t, strings.contains(err, "cross-bridge replay rejected"), "error must cite cross-bridge destination mismatch")
}

@(test)
test_security_tampering_timestamp_or_ciphertext_tag_failure :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)
	defer bridge_vault_lock()

	vpath, bpath, had_file := test_isolate_disk_vault_key()
	defer test_restore_disk_vault_key(vpath, bpath, had_file)

	bridge_vault_lock()
	unseal_nonce_cache_clear(&g_unseal_nonce_cache)
	bridge_unseal_init()

	bridge_id := "brg_sec_tamper_test"
	bridge_pub_hex := bridge_get_public_key_hex()
	test_key := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	now_ms := time.to_unix_nanoseconds(time.now()) / 1_000_000

	// 1. AAD tampering (tampered AAD at creation time)
	payload_aad_tamper := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_tamper_aad_unique_nonce", true)
	defer delete(payload_aad_tamper)
	ok_aad, err_aad := bridge_unseal_decrypt_and_verify(payload_aad_tamper, bridge_id, now_ms)
	testing.expect(t, !ok_aad, "tampered AAD must fail AEAD tag verification")
	testing.expect(t, strings.contains(err_aad, "AEAD tag verification failed"), "must cite AEAD tag failure")

	// 2. Wire timestamp mutation tampering (mutating wire timestamp causes computed AAD to mismatch encrypted AAD)
	payload_valid_ts := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_tamper_ts_unique_nonce")
	defer delete(payload_valid_ts)
	mutated_ts_payload, _ := strings.replace(payload_valid_ts, fmt.tprintf(`"timestamp":%d`, now_ms), fmt.tprintf(`"timestamp":%d`, now_ms + 1000), 1)
	defer delete(mutated_ts_payload)
	ok_ts, err_ts := bridge_unseal_decrypt_and_verify(mutated_ts_payload, bridge_id, now_ms)
	testing.expect(t, !ok_ts, "mutated wire timestamp must cause AEAD tag mismatch")
	testing.expect(t, strings.contains(err_ts, "AEAD tag verification failed"), "must cite AEAD tag failure on mutated timestamp")

	// 3. Ciphertext corruption tampering
	payload_valid_ct := create_sec_test_envelope(bridge_id, bridge_pub_hex, test_key, now_ms, "sec_tamper_ct_unique_nonce")
	defer delete(payload_valid_ct)
	corrupted_ct_payload, _ := strings.replace(payload_valid_ct, `"ciphertext":"`, `"ciphertext":"0000`, 1)
	defer delete(corrupted_ct_payload)
	ok_ct, err_ct := bridge_unseal_decrypt_and_verify(corrupted_ct_payload, bridge_id, now_ms)
	testing.expect(t, !ok_ct, "corrupted ciphertext must fail AEAD tag verification")
	testing.expect(t, strings.contains(err_ct, "AEAD tag verification failed"), "must cite AEAD tag failure on corrupted ciphertext")
}

@(test)
test_security_self_hosted_unconfigured_executes_unencrypted_without_errors :: proc(t: ^testing.T) {
	sync.mutex_lock(&keystore_test_mutex)
	defer sync.mutex_unlock(&keystore_test_mutex)

	vpath, bpath, had_file := test_isolate_disk_vault_key()
	defer test_restore_disk_vault_key(vpath, bpath, had_file)

	keystore_lock_and_purge()
	defer keystore_lock_and_purge()

	prev_env, had_env := os.lookup_env("HEIMDALL_VAULT_KEY", context.temp_allocator)
	defer {
		if had_env {
			_ = os.set_env("HEIMDALL_VAULT_KEY", prev_env)
		} else {
			_ = os.unset_env("HEIMDALL_VAULT_KEY")
		}
	}
	os.unset_env("HEIMDALL_VAULT_KEY")

	// Unconfigured self-hosted workspace
	bridge_workspace_vault_configured = false
	defer { bridge_workspace_vault_configured = false }

	// 1. Vault status must report Disabled
	testing.expect_value(t, bridge_vault_status(), Vault_Status.Disabled)
	testing.expect_value(t, bridge_vault_status_string(), "disabled")

	// 2. Filesystem operations run unencrypted without errors or blocking
	test_filename := "heimdall_selfhosted_test_file.txt"
	test_content := "Plaintext Unencrypted Content for Self-Hosted Mode"
	tmp_dir := "/tmp"

	write_res := bridge_fs_write_file(test_filename, test_content, tmp_dir)
	testing.expect(t, write_res.ok, "fs_write_file must succeed when vault is Disabled")

	read_res := bridge_fs_read_file(test_filename, tmp_dir, 0, 100)
	testing.expect(t, read_res.ok, "fs_read_file must succeed when vault is Disabled")
	testing.expect_value(t, read_res.content, test_content)
	testing.expect(t, !strings.has_prefix(read_res.content, VAULT_ARMOR_PREFIX), "content must NOT be vault-armored")
	defer delete(read_res.content)

	// Clean up created test file
	full_path := fmt.tprintf("%s/%s", tmp_dir, test_filename)
	_ = os.remove(full_path)

	// 3. Shell streaming emits unarmored base64 without delay or locked banner
	stream_data := transmute([]byte)string("echo Hello Self-Hosted World\n")
	bridge_pty_stream_emit_frame(nil, "sh_selfhosted_disabled_01", stream_data)

	frames := bridge_pty_stream_take_outgoing()
	defer {
		for f in frames do delete(f, runtime.heap_allocator())
		delete(frames)
	}

	testing.expect(t, len(frames) > 0, "stream frame must be emitted")
	if len(frames) > 0 {
		first_frame := frames[0]
		testing.expect(t, !strings.contains(first_frame, "Vault locked"), "must not emit locked warning banner")
		testing.expect(t, !strings.contains(first_frame, VAULT_ARMOR_PREFIX), "must not emit vault:v1: armored data")
		testing.expect(t, strings.contains(first_frame, `"data_b64":"`), "must emit plaintext data_b64 frame")
	}
}
