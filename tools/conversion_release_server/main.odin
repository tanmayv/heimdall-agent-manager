package main

// Fake GitHub release repo for the cross-OS conversion CI (P2-7, tests/e2e/conversion_e2e.mjs).
// Packs a directory (a built, supervisor-capable bundle: bin/, share/...) into this target's
// bundle archive, signs a release manifest for it with the TEST-ONLY e2e key
// (testkit.e2e_key; only -define:HEIMDALL_SUPERVISOR_TEST builds trust it) and serves it
// the way GitHub does on loopback (/gh/<repo>/releases/download/<tag>/<asset>,
// /api/repos/<repo>/releases[/latest]). A test build of `ham-bridge setup` reaches it
// through HEIMDALL_SUPERVISOR_TEST_ORIGIN=http://127.0.0.1:<port>.
//
//   conversion_release_server --dir <bundle dir> --tag vX.Y.Z --port-file <file> [--out <dir>]
//
// --out also writes the archive, manifest and signature there. The server runs until killed.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "odin_test:supervisor/fetch"
import tk "odin_test:supervisor/testkit"

main :: proc() {
	dir, tag, port_file, out := "", "", "", ""
	args := os.args[1:]
	for i := 0; i + 1 < len(args); i += 2 {
		switch args[i] {
		case "--dir": dir = args[i + 1]
		case "--tag": tag = args[i + 1]
		case "--port-file": port_file = args[i + 1]
		case "--out": out = args[i + 1]
		case: fmt.eprintln("unknown option", args[i]); os.exit(2)
		}
	}
	if dir == "" || tag == "" || port_file == "" || !strings.has_prefix(tag, "v") {
		fmt.eprintln("usage: conversion_release_server --dir <bundle dir> --tag vX.Y.Z --port-file <file> [--out <dir>]")
		os.exit(2)
	}
	files := make([dynamic]tk.Bundle_File)
	collect(dir, "", &files)
	if len(files) == 0 {
		fmt.eprintln("no files under", dir)
		os.exit(1)
	}
	key := tk.e2e_key()
	rel := tk.make_release(&key, {tag = tag, files = files[:]})
	if out != "" {
		_ = os.make_directory_all(out)
		_ = os.write_entire_file_from_bytes(join(out, rel.asset), rel.bundle)
		_ = os.write_entire_file_from_bytes(join(out, fetch.MANIFEST_ASSET), transmute([]byte)rel.manifest)
		_ = os.write_entire_file_from_bytes(join(out, fetch.SIGNATURE_ASSET), transmute([]byte)rel.signature)
	}
	g: tk.Fake_GitHub
	if !tk.github_start(&g) {
		fmt.eprintln("cannot listen on loopback")
		os.exit(1)
	}
	tk.github_publish(&g, rel)
	// Written last and atomically enough for a poller: the port file's presence means ready.
	tmp := strings.concatenate({port_file, ".tmp"})
	_ = os.write_entire_file_from_bytes(tmp, transmute([]byte)fmt.tprintf("%d", g.port))
	_ = os.rename(tmp, port_file)
	fmt.printfln("serving %s (%s, %d bytes, sha256 %s) on 127.0.0.1:%d", tag, rel.asset, len(rel.bundle), rel.sha256, g.port)
	for {time.sleep(time.Second)}
}

collect :: proc(root, rel: string, files: ^[dynamic]tk.Bundle_File) {
	here := root if rel == "" else join(root, rel)
	entries, err := os.read_directory_by_path(here, -1, context.allocator)
	if err != nil do return
	for e in entries {
		r := e.name if rel == "" else strings.concatenate({rel, "/", e.name})
		if e.type == .Directory {
			collect(root, r, files)
			continue
		}
		if e.type != .Regular do continue // bundles are symlink-free
		data, rerr := os.read_entire_file_from_path(e.fullpath, context.allocator)
		if rerr != nil do continue
		exec := strings.has_suffix(e.name, ".exe") || strings.has_suffix(e.name, ".ps1") || .Execute_User in e.mode || strings.has_prefix(r, "bin/")
		append(files, tk.Bundle_File{path = strings.clone(r), data = data, exec = exec})
	}
}

join :: proc(a, b: string) -> string {
	return strings.concatenate({a, "/", b}, context.temp_allocator)
}
