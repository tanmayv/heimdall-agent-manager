package main

import "core:crypto/sha2"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"

ARTIFACT_DEFAULT_MAX_BYTES :: 10 * 1024 * 1024

Artifact_Validation_Result :: struct {
	kind:       string,
	mime:       string,
	ext:        string,
	size_bytes: i64,
	sha256:     string,
	message:    string,
	ok:         bool,
}

artifact_blob_root: string

artifact_storage_init :: proc(data_dir, configured_blob_dir: string) -> bool {
	root := strings.trim_space(configured_blob_dir)
	if root != "" {
		root = expand_home(root)
	} else {
		root = fmt.tprintf("%s/artifacts/blobs", data_dir)
	}
	if err := os.make_directory_all(root); err != nil {
		fmt.printfln("artifact_storage_init: make_directory_all failed for %s", root)
		return false
	}
	artifact_blob_root = strings.clone(root)
	return true
}

artifact_blob_root_path :: proc() -> string {
	return artifact_blob_root
}

artifact_max_bytes_limit :: proc() -> int {
	if server_config.daemon.artifact_max_bytes > 0 do return server_config.daemon.artifact_max_bytes
	return ARTIFACT_DEFAULT_MAX_BYTES
}

artifact_generate_id :: proc() -> string {
	bytes: [16]byte
	if rand.read(bytes[:]) != len(bytes) {
		now := u64(router_now_unix_ms())
		for i in 0..<len(bytes) {
			bytes[i] = byte((now >> uint((i % 8) * 8)) & 0xff)
		}
	}
	builder := strings.builder_make()
	strings.write_string(&builder, contracts.ARTIFACT_ID_PREFIX)
	for b in bytes do hex_write_byte(&builder, b)
	return strings.to_string(builder)
}

artifact_blob_rel_path :: proc(artifact_id: string) -> string {
	suffix := artifact_id
	if strings.has_prefix(suffix, contracts.ARTIFACT_ID_PREFIX) {
		suffix = suffix[len(contracts.ARTIFACT_ID_PREFIX):]
	}
	shard_a := "00"
	shard_b := "00"
	if len(suffix) >= 2 do shard_a = suffix[:2]
	if len(suffix) >= 4 do shard_b = suffix[2:4]
	return fmt.tprintf("%s/%s/%s", shard_a, shard_b, artifact_id)
}

artifact_blob_abs_path :: proc(rel_path: string) -> string {
	if artifact_blob_root == "" do return rel_path
	return fmt.tprintf("%s/%s", artifact_blob_root, rel_path)
}

artifact_validate_payload :: proc(kind, mime, ext: string, data: []byte, max_bytes: int) -> Artifact_Validation_Result {
	validated, ok := contracts.artifact_validate_kind_mime_ext(kind, mime, ext)
	if !ok {
		return Artifact_Validation_Result{message = "artifact kind/mime/ext failed allowlist validation", ok = false}
	}
	limit := max_bytes
	if limit <= 0 do limit = artifact_max_bytes_limit()
	size_bytes := i64(len(data))
	if size_bytes > i64(limit) {
		return Artifact_Validation_Result{kind = validated.kind, mime = validated.mime, ext = validated.ext, size_bytes = size_bytes, message = fmt.tprintf("artifact exceeds size cap of %d bytes", limit), ok = false}
	}
	if !contracts.artifact_kind_matches_magic_bytes(validated.kind, data) {
		return Artifact_Validation_Result{kind = validated.kind, mime = validated.mime, ext = validated.ext, size_bytes = size_bytes, message = "artifact bytes do not match declared image kind", ok = false}
	}
	return Artifact_Validation_Result{kind = validated.kind, mime = validated.mime, ext = validated.ext, size_bytes = size_bytes, sha256 = artifact_sha256_hex(data), ok = true}
}

artifact_write_blob :: proc(artifact_id: string, data: []byte) -> (rel_path, sha256: string, size_bytes: i64, ok: bool) {
	rel_path = artifact_blob_rel_path(artifact_id)
	abs_path := artifact_blob_abs_path(rel_path)
	blob_dir := parent_dir(abs_path)
	if !os.is_dir(blob_dir) {
		if err := os.make_directory_all(blob_dir); err != nil {
			fmt.println("artifact_write_blob: make_directory_all failed", "dir", blob_dir, "file", abs_path, "err", err)
			return "", "", 0, false
		}
	}
	// os.write_entire_file is create-only on some platforms. Remove first so
	// update can replace the existing blob bytes at the same sharded path.
	_ = os.remove(abs_path)
	if err := os.write_entire_file(abs_path, data); err != nil {
		fmt.println("artifact_write_blob: write failed", "dir", blob_dir, "file", abs_path, "err", err)
		return "", "", 0, false
	}
	return strings.clone(rel_path), artifact_sha256_hex(data), i64(len(data)), true
}

artifact_read_blob :: proc(rel_path: string) -> ([]byte, bool) {
	if rel_path == "" do return nil, false
	data, err := os.read_entire_file(artifact_blob_abs_path(rel_path), context.allocator)
	if err != nil do return nil, false
	return data, true
}

artifact_delete_blob :: proc(rel_path: string) -> bool {
	if rel_path == "" do return true
	_ = os.remove(artifact_blob_abs_path(rel_path))
	return true
}

artifact_sha256_hex :: proc(data: []byte) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	builder := strings.builder_make()
	for b in digest do hex_write_byte(&builder, b)
	return strings.to_string(builder)
}
