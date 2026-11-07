#!/usr/bin/env python3
"""Prepare pinned vendor bytes in a private cache; never install or execute them."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import urllib.request

PIN = Path(__file__).resolve().parents[1] / "tools/pty_host/fixtures/codex-darwin-x64-0.162.0.json"
MAX_ARCHIVE = 256 * 1024 * 1024
MAX_IMAGE = 512 * 1024 * 1024


def verify_archive(path, integrity):
    algorithm, encoded = integrity.split("-", 1)
    if algorithm != "sha512":
        raise ValueError("unsupported integrity algorithm")
    expected = base64.b64decode(encoded, validate=True)
    digest = hashlib.sha512()
    total = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            total += len(chunk)
            if total > MAX_ARCHIVE:
                raise ValueError("archive exceeds bound")
            digest.update(chunk)
    if digest.digest() != expected:
        raise ValueError("archive integrity mismatch")


def extract_image(archive, destination, pin):
    verify_archive(archive, pin["integrity"])
    with tarfile.open(archive, "r:gz") as package:
        members = package.getmembers()
        if len(members) > 1024 or sum(m.size for m in members) > 1024 * 1024 * 1024:
            raise ValueError("package layout exceeds bound")
        matches = [m for m in members if m.name == pin["member"]]
        if len(matches) != 1 or not matches[0].isfile() or not 4 <= matches[0].size <= MAX_IMAGE:
            raise ValueError("native member missing, duplicate or not a regular bounded file")
        # Do not extract archive paths, symlinks, launchers, hooks or lifecycle scripts.
        source = package.extractfile(matches[0])
        digest = hashlib.sha256()
        with destination.open("xb") as output:
            for chunk in iter(lambda: source.read(65536), b""):
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != pin["native_sha256"]:
            destination.unlink()
            raise ValueError("actual native image digest mismatch")
    os.chmod(destination, 0o500)


def private_output(raw):
    cache = Path.home() / ".cache/heimdall-tests"
    cache.mkdir(parents=True, exist_ok=True)
    cache = cache.resolve()
    out = Path(raw).absolute()
    # A fresh direct child avoids symlink/parent traversal and accidental use of
    # system profiles, the Nix store, existing package roots or a live directory.
    if out.parent.resolve() != cache or out.name in (".", "..") or out.exists() or out.is_symlink():
        raise ValueError("--out must be a fresh direct child of ~/.cache/heimdall-tests")
    out.mkdir(mode=0o700)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", help="Fresh private cache directory")
    parser.add_argument("--archive", type=Path, help="Optional already downloaded pinned archive")
    parser.add_argument("--print-plan", action="store_true")
    args = parser.parse_args()
    pin = json.loads(PIN.read_text())
    if args.print_plan:
        print(json.dumps(pin, indent=2))
        return
    if not args.out:
        parser.error("--out is required")
    out = private_output(args.out)
    try:
        archive = out / "vendor.tgz"
        if args.archive:
            if args.archive.stat().st_size > MAX_ARCHIVE:
                raise ValueError("archive exceeds bound")
            shutil.copyfile(args.archive, archive)
        else:
            # Fixed URL and integrity, no mutable dist-tag or npm lifecycle scripts.
            with urllib.request.urlopen(pin["url"], timeout=30) as response, archive.open("xb") as target:
                total = 0
                for chunk in iter(lambda: response.read(65536), b""):
                    total += len(chunk)
                    if total > MAX_ARCHIVE:
                        raise ValueError("download exceeds bound")
                    target.write(chunk)
        image = out / "codex"
        extract_image(archive, image, pin)
        manifest = dict(pin, image=str(image), staging_uid=os.getuid(),
                        production_admissible=False, executed=False,
                        missing_proof="privileged protection/closure/daemon/updater/delete/GC/lifetime model")
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(manifest, indent=2))
    except BaseException:
        shutil.rmtree(out)
        raise


if __name__ == "__main__":
    main()
