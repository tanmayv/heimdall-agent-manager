package fetch

// prepare_release: spec §14 steps 1-11 for one operation, ending with a valid
// release tree under <data>/releases/ that no pointer names yet. The engine
// (T13) journals `downloading` before calling it and `verified` (with the
// returned tree name) after it; on error it journals `failed <code>`.
//
// What it writes, and only that:
//   <data>/supervisor/downloads/<op_id>/   manifest, signature, bundle (W9)
//   <data>/releases/.staging-<op_id>/      deleted on failure, renamed on success
//   <data>/releases/<tree>/                the new tree (deleted again if the
//                                          preflight fails; never a live tree)
//   <data>/releases/.trash-<tree>-<op_id>  only to delete a damaged non-live tree
// It never touches pointers (current/previous/known-good), live trees,
// processes, the journal or anything outside <data>.

import "core:os"
import "core:strings"

Local_Release :: struct {
	manifest_path:  string,
	signature_path: string,
	bundle_path:    string,
}

Prepare_Input :: struct {
	instance_root:   string, // <data>
	op_id:           string,
	tag:             string, // release tag the resolver picked ("v0.6.0")
	expected_asset:  string, // this target's bundle asset in that release; "" = unchecked
	// Exactly one source: GitHub through `downloader`, or files already on
	// disk (offline `repair`, §16) in `local`.
	downloader:      Downloader,
	local:           Local_Release,
	verify:          Verify_Options, // now, check_expiry, pins, target; tag/asset set from above
	// Step 5 (eligibility, §13.2) runs between verification and download.
	eligible:        proc(user: rawptr, m: ^Manifest) -> Error,
	eligible_user:   rawptr,
	// Called with `eligible_user` once the bundle is downloaded and its size and SHA-256
	// matched (end of step 6, J6 `downloading -> verifying`), before extraction. Not
	// called when an identical valid tree is reused (J5). nil = no hook.
	bundle_ready:    proc(user: rawptr, m: ^Manifest) -> Error,
	live:            []string, // W1 live tree names
	os_policy:       Os_Signature_Policy,
	limits:          Limits,
	preflight:       []string, // nil = DEFAULT_PREFLIGHT
	preflight_timeout_ms: int, // 0 = PREFLIGHT_TIMEOUT_MS
	retry:           Retry_Policy,
}

// default_prepare_input fills the policy fields with the spec defaults.
default_prepare_input :: proc() -> Prepare_Input {
	return Prepare_Input{os_policy = DEFAULT_OS_SIGNATURE_POLICY, limits = DEFAULT_LIMITS, retry = DEFAULT_RETRY}
}

Prepared :: struct {
	tree:     string, // directory name under releases/
	reused:   bool, // an identical valid tree existed; nothing was unpacked
	manifest: Manifest, // owned, free with manifest_destroy
}

ID_CHARS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

@(private)
valid_op_id :: proc(op_id: string) -> bool {
	if len(op_id) == 0 || len(op_id) > 64 do return false
	for c in transmute([]byte)op_id do if strings.index_byte(ID_CHARS, c) < 0 do return false
	return true
}

prepare_release :: proc(input: Prepare_Input, allocator := context.allocator) -> (out: Prepared, err: Error) {
	in_ := input
	if !valid_op_id(in_.op_id) do return out, fail(.Fs_Error, "invalid op_id %q", in_.op_id)
	if in_.instance_root == "" do return out, fail(.Fs_Error, "no instance root")
	if in_.limits == {} do in_.limits = DEFAULT_LIMITS
	if in_.retry.budget_ms == 0 && in_.retry.first_ms == 0 do in_.retry = DEFAULT_RETRY
	preflight := in_.preflight if in_.preflight != nil else DEFAULT_PREFLIGHT
	timeout := in_.preflight_timeout_ms if in_.preflight_timeout_ms > 0 else PREFLIGHT_TIMEOUT_MS
	use_local := in_.local.manifest_path != ""

	supervisor_dir := native_join(in_.instance_root, "supervisor")
	downloads := native_join(supervisor_dir, strings.concatenate({"downloads", "/" if ODIN_OS != .Windows else "\\", in_.op_id}, context.temp_allocator))
	releases := native_join(in_.instance_root, "releases")
	if e := os.make_directory_all(downloads, DIR_PERMS_PRIVATE); e != nil && e != os.General_Error.Exist {
		return out, fail(.Fs_Error, "mkdir %s: %v", downloads, e)
	}
	if e := os.make_directory_all(releases, DIR_PERMS); e != nil && e != os.General_Error.Exist {
		return out, fail(.Fs_Error, "mkdir %s: %v", releases, e)
	}

	// Steps 1-4.
	manifest_bytes, signature_bytes: []byte
	if use_local {
		manifest_bytes = read_capped(in_.local.manifest_path, MAX_MANIFEST_BYTES, .Manifest_Invalid) or_return
		signature_bytes = read_capped(in_.local.signature_path, MAX_SIGNATURE_BYTES, .Signature_Invalid) or_return
	} else {
		murl := asset_url(in_.tag, MANIFEST_ASSET) or_return
		surl := asset_url(in_.tag, SIGNATURE_ASSET) or_return
		manifest_bytes = download_small(in_.downloader, murl, MAX_MANIFEST_BYTES) or_return
		signature_bytes = download_small(in_.downloader, surl, MAX_SIGNATURE_BYTES) or_return
		write_durable(native_join(downloads, MANIFEST_ASSET), manifest_bytes) or_return
		write_durable(native_join(downloads, SIGNATURE_ASSET), signature_bytes) or_return
	}
	opts := in_.verify
	opts.expected_tag = in_.tag
	opts.expected_asset = in_.expected_asset
	m := verify_manifest(manifest_bytes, signature_bytes, opts, allocator) or_return
	defer if err != nil do manifest_destroy(&m, allocator)

	// Step 5.
	if in_.eligible != nil do in_.eligible(in_.eligible_user, &m) or_return

	kind, kind_ok := archive_kind_for_asset(m.asset)
	if !kind_ok do return out, fail(.Manifest_Invalid, "unsupported bundle format %q", m.asset)

	// J5: an identical valid tree is reused without downloading.
	if base := tree_base_name(&m); tree_intact(native_join(releases, base), &m) {
		return Prepared{tree = strings.clone(base, allocator), reused = true, manifest = m}, nil
	}

	// Step 6.
	bundle: string
	if use_local {
		verify_bundle_file(in_.local.bundle_path, &m) or_return
		bundle = in_.local.bundle_path
	} else {
		bundle = download_bundle(in_.downloader, &m, downloads) or_return
	}
	if in_.bundle_ready != nil do in_.bundle_ready(in_.eligible_user, &m) or_return

	// Step 7.
	staging_name := strings.concatenate({".staging-", in_.op_id}, context.temp_allocator)
	staging := native_join(releases, staging_name)
	os.remove_all(staging) // J6/J7: redo from a clean staging dir
	if os.exists(staging) do return out, fail(.Fs_Busy, "cannot clear %s", staging)
	if e := os.make_directory(staging, DIR_PERMS); e != nil do return out, fail(.Fs_Error, "mkdir %s: %v", staging, e)
	keep_staging := false
	defer if !keep_staging do os.remove_all(staging)

	extracted := extract_archive(bundle, staging, kind, in_.limits) or_return

	// Step 8.
	check_os_signatures(staging, extracted.files[:], in_.os_policy) or_return

	// Step 9.
	write_tree_metadata(staging, &m, &extracted) or_return
	name, choice := choose_tree_name(releases, &m, in_.live, in_.op_id, in_.retry) or_return
	if choice == .Reuse do return Prepared{tree = strings.clone(name, allocator), reused = true, manifest = m}, nil
	final := native_join(releases, name)
	rename_with_retry(staging, final, in_.retry) or_return
	keep_staging = true // it is the final tree now
	sync_dir(releases) or_return

	// Steps 10-11. A failure leaves a tree without .complete (never valid);
	// delete it now, or GC does later.
	if perr := run_preflight(final, preflight, m.version, timeout); perr != nil {
		_ = remove_tree(releases, name, in_.op_id, in_.retry)
		return out, perr
	}
	if cerr := mark_complete(final, in_.op_id); cerr != nil {
		_ = remove_tree(releases, name, in_.op_id, in_.retry)
		return out, cerr
	}
	return Prepared{tree = strings.clone(name, allocator), manifest = m}, nil
}

@(private)
DIR_PERMS_PRIVATE :: os.Permissions{.Read_User, .Write_User, .Execute_User}
