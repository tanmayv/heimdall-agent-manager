package tests

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import bridge "odin_test:bridge"

@(test)
test_bootstrap_fragment_hash :: proc(t: ^testing.T) {
	input := "## Agent Identity & Instructions\nYou are an expert assistant."
	buf: [32]byte
	hash.hash_string_to_buffer(.SHA256, input, buf[:])
	hex_str := hex.encode(buf[:])
	defer delete(hex_str)
	expected := strings.concatenate({"sha256:", string(hex_str)})
	defer delete(expected)

	actual := bridge.bootstrap_cache_hash_filename(expected)
	testing.expect_value(t, actual, string(hex_str))
}

@(test)
test_bootstrap_cache_put_get_evict :: proc(t: ^testing.T) {
	tmp_dir := "/tmp/heimdall_test_bootstrap_cache"
	_ = os.remove_all(tmp_dir)
	defer _ = os.remove_all(tmp_dir)

	var_cache: bridge.Bootstrap_Cache
	bridge.bootstrap_cache_init(&var_cache, tmp_dir, 100)

	body1 := "Fragment 1 content: Hello World!"
	buf1: [32]byte
	hash.hash_string_to_buffer(.SHA256, body1, buf1[:])
	hex1 := hex.encode(buf1[:])
	defer delete(hex1)
	hash1 := strings.concatenate({"sha256:", string(hex1)})
	defer delete(hash1)

	ok1 := bridge.bootstrap_cache_put(&var_cache, hash1, body1)
	testing.expect(t, ok1, "put 1 should succeed")
	testing.expect(t, bridge.bootstrap_cache_has(&var_cache, hash1), "cache should have hash1")

	got1, got1_ok := bridge.bootstrap_cache_get(&var_cache, hash1)
	testing.expect(t, got1_ok, "get 1 should succeed")
	testing.expect_value(t, got1, body1)

	bad_ok := bridge.bootstrap_cache_put(&var_cache, "sha256:0000000000000000000000000000000000000000000000000000000000000000", body1)
	testing.expect(t, !bad_ok, "put with mismatching hash must fail")
}
