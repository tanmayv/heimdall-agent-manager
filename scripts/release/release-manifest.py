#!/usr/bin/env python3
"""Generate and verify the minisign-signed release manifest (report §6.5 item 1).

The manifest is the root of trust for a bridge release: it names every
per-target bridge bundle with its size and SHA-256, and it is signed with the
release minisign key. Verifiers accept only the public keys pinned in
scripts/release/minisign/ (two keys, for rotation; docs/release-signing.md).

    release-manifest.py key-id <file.pub|file.minisig>
    release-manifest.py generate --tag vX.Y.Z --commit <sha> --key-id <hex16>
        --asset <target>=<path> [--asset ...] [--policy <json>] --out <manifest>
    release-manifest.py trusted-comment --manifest <manifest> [--policy <json>]
    release-manifest.py verify --manifest <m> --signature <m.minisig>
        [--keys-dir <dir>] [--dist <dir>] [--target <t> ...] [--now <unix>]

`verify` checks, in order and failing closed: the signature key id is pinned;
minisign accepts the signature and the trusted comment with that pinned key;
the trusted comment and the manifest agree (version, key id); the manifest is
not expired; and, with --dist, every listed (or every --target) bundle exists
with the exact size and SHA-256. Exit 0 = verified, 1 = rejected, 2 = usage,
3 = internal error (I/O, missing minisign, crash): never a verdict.

Signature checking is delegated to the `minisign` binary (Ed25519 is not in
the Python standard library); everything else is stdlib only.
"""

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

MANIFEST_SCHEMA = 1
MANIFEST_KIND = "heimdall-release-manifest"
ROOT = Path(__file__).resolve().parents[2]
DEFAULT_KEYS_DIR = ROOT / "scripts/release/minisign"
DEFAULT_POLICY = DEFAULT_KEYS_DIR / "manifest-policy.json"

TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$")
TARGET_RE = re.compile(r"^[a-z0-9]+-[a-z0-9]+$")
KEY_ID_RE = re.compile(r"^[0-9A-F]{16}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


class Rejected(Exception):
    """Verification failed; the message says why."""


# --- minisign file formats -------------------------------------------------

def _key_id_from_blob(blob, expected_len, what):
    if len(blob) != expected_len:
        raise Rejected(f"{what}: unexpected length {len(blob)}")
    # minisign prints the 8-byte key number as a little-endian u64 in hex.
    return blob[2:10][::-1].hex().upper()


def _b64(line, what):
    try:
        return base64.b64decode(line.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise Rejected(f"{what}: invalid base64") from exc


def public_key_id(path):
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    if len(lines) < 2 or not lines[0].startswith("untrusted comment:"):
        raise Rejected(f"{path}: not a minisign public key")
    blob = _b64(lines[1], str(path))
    if blob[:2] != b"Ed":
        raise Rejected(f"{path}: unsupported public key algorithm")
    return _key_id_from_blob(blob, 42, str(path))


def parse_signature(path):
    """Return (key_id, trusted_comment_text) from a .minisig file (unverified)."""
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    if (len(lines) < 4 or not lines[0].startswith("untrusted comment:")
            or not lines[2].startswith("trusted comment: ")):
        raise Rejected(f"{path}: not a minisign signature")
    blob = _b64(lines[1], str(path))
    if blob[:2] not in (b"ED", b"Ed"):
        raise Rejected(f"{path}: unsupported signature algorithm")
    return _key_id_from_blob(blob, 74, str(path)), lines[2][len("trusted comment: "):]


def pinned_keys(keys_dir):
    keys = {}
    for pub in sorted(Path(keys_dir).glob("*.pub")):
        key_id = public_key_id(pub)
        if key_id in keys:
            raise Rejected(f"duplicate pinned key id {key_id}: {keys[key_id]} and {pub}")
        keys[key_id] = pub
    if not keys:
        raise Rejected(f"no pinned public keys (*.pub) in {keys_dir}")
    return keys


# --- manifest ---------------------------------------------------------------

# Engine spec 13.4: required whenever min_engine >= 1.
ENGINE_FIELDS = ("state_schema", "state_compat_min", "min_launcher_abi")


def load_policy(path):
    policy = json.loads(Path(path).read_text(encoding="utf-8"))
    for field in ("min_engine", "journal_schema", "expires_after_days"):
        if not isinstance(policy.get(field), int) or isinstance(policy[field], bool) or policy[field] < 0:
            raise SystemExit(f"{path}: {field} must be a non-negative integer")
    if policy["expires_after_days"] < 1:
        raise SystemExit(f"{path}: expires_after_days must be at least 1")
    if policy["min_engine"] >= 1:
        # Engine spec 13.4: a release that claims an engine declares all of them.
        for field in ENGINE_FIELDS:
            if not isinstance(policy.get(field), int) or isinstance(policy[field], bool) or policy[field] < 1:
                raise SystemExit(f"{path}: {field} must be a positive integer when min_engine >= 1")
    return policy


def file_digest(path):
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def canonical_json(value):
    """Byte-stable encoding: sorted keys, no insignificant whitespace, LF end."""
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def build_manifest(tag, commit, key_id, assets, policy):
    if not TAG_RE.match(tag):
        raise SystemExit(f"invalid release tag: {tag}")
    if not SHA_RE.match(commit):
        raise SystemExit(f"invalid commit sha: {commit}")
    if not KEY_ID_RE.match(key_id):
        raise SystemExit(f"invalid key id: {key_id}")
    if not assets:
        raise SystemExit("at least one --asset is required")
    targets = {}
    for target, path in assets:
        if not TARGET_RE.match(target):
            raise SystemExit(f"invalid target: {target}")
        if target in targets:
            raise SystemExit(f"duplicate target: {target}")
        size, sha256 = file_digest(path)
        targets[target] = {"asset": Path(path).name, "size": size, "sha256": sha256}
    engine = {f: policy[f] for f in ENGINE_FIELDS} if policy["min_engine"] >= 1 else {}
    return {
        **engine,
        "kind": MANIFEST_KIND,
        "schema": MANIFEST_SCHEMA,
        "tag": tag,
        "version": tag[1:],
        "commit": commit,
        "key_id": key_id,
        "min_engine": policy["min_engine"],
        "journal_schema": policy["journal_schema"],
        "targets": targets,
    }


def trusted_comment(manifest, policy, now):
    """`{version, seq, expires}` (report §6.5): seq is the signing time, so a
    later signature always carries a larger seq; expires bounds freeze attacks."""
    return json.dumps({
        "version": manifest["tag"],
        "seq": now,
        "expires": now + policy["expires_after_days"] * 86400,
    }, sort_keys=True, separators=(",", ":"))


def check_manifest_shape(manifest):
    def need(cond, why):
        if not cond:
            raise Rejected(f"manifest: {why}")
    need(isinstance(manifest, dict), "not an object")
    need(manifest.get("kind") == MANIFEST_KIND, "wrong kind")
    need(manifest.get("schema") == MANIFEST_SCHEMA, f"unsupported schema {manifest.get('schema')!r}")
    tag = manifest.get("tag")
    need(isinstance(tag, str) and TAG_RE.match(tag), "invalid tag")
    need(manifest.get("version") == tag[1:], "version does not match tag")
    need(isinstance(manifest.get("commit"), str) and SHA_RE.match(manifest["commit"]), "invalid commit")
    need(isinstance(manifest.get("key_id"), str) and KEY_ID_RE.match(manifest["key_id"]), "invalid key_id")
    for field in ("min_engine", "journal_schema"):
        value = manifest.get(field)
        need(isinstance(value, int) and not isinstance(value, bool) and value >= 0, f"invalid {field}")
    if manifest["min_engine"] >= 1:
        for field in ENGINE_FIELDS:
            value = manifest.get(field)
            need(isinstance(value, int) and not isinstance(value, bool) and value >= 1,
                 f"manifest_incomplete: {field} missing or invalid")
    targets = manifest.get("targets")
    need(isinstance(targets, dict) and targets, "no targets")
    for target, entry in targets.items():
        need(TARGET_RE.match(target), f"invalid target {target!r}")
        need(isinstance(entry, dict), f"{target}: not an object")
        asset = entry.get("asset")
        # A bare file name: never a path a verifier could be steered by.
        need(isinstance(asset, str) and asset == Path(asset).name and asset not in ("", ".", "..")
             and "\\" not in asset, f"{target}: invalid asset name")
        size = entry.get("size")
        need(isinstance(size, int) and not isinstance(size, bool) and size >= 0, f"{target}: invalid size")
        need(isinstance(entry.get("sha256"), str) and DIGEST_RE.match(entry["sha256"]), f"{target}: invalid sha256")


def verify(manifest_path, signature_path, keys_dir, dist=None, targets=None, now=None, minisign="minisign"):
    """Return the verified manifest dict or raise Rejected."""
    keys = pinned_keys(keys_dir)
    with tempfile.TemporaryDirectory() as tmp:
        # Verify and then parse the same private copies (no swap in between).
        manifest_copy = Path(tmp) / "manifest.json"
        signature_copy = Path(tmp) / "manifest.json.minisig"
        shutil.copyfile(manifest_path, manifest_copy)
        shutil.copyfile(signature_path, signature_copy)
        key_id, comment = parse_signature(signature_copy)
        if key_id not in keys:
            raise Rejected(f"signature key id {key_id} is not pinned (pinned: {', '.join(sorted(keys))})")
        result = subprocess.run(
            [minisign, "-V", "-q", "-p", str(keys[key_id]), "-m", str(manifest_copy), "-x", str(signature_copy)],
            stdin=subprocess.DEVNULL, capture_output=True, text=True)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            raise Rejected(f"minisign rejected the signature: {detail or 'exit ' + str(result.returncode)}")
        raw = manifest_copy.read_bytes()
    try:
        manifest = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Rejected(f"manifest: invalid JSON ({exc})") from exc
    check_manifest_shape(manifest)
    if raw != canonical_json(manifest):
        raise Rejected("manifest: not in canonical form")
    if manifest["key_id"] != key_id:
        raise Rejected(f"manifest key_id {manifest['key_id']} differs from signing key {key_id}")
    try:
        trusted = json.loads(comment)
    except json.JSONDecodeError as exc:
        raise Rejected("trusted comment: invalid JSON") from exc
    if not isinstance(trusted, dict) or trusted.get("version") != manifest["tag"]:
        raise Rejected("trusted comment version does not match the manifest tag")
    for field in ("seq", "expires"):
        if not isinstance(trusted.get(field), int) or isinstance(trusted[field], bool):
            raise Rejected(f"trusted comment: invalid {field}")
    current = int(time.time()) if now is None else now
    if trusted["expires"] <= current:
        raise Rejected(f"manifest expired at {trusted['expires']} (now {current})")
    if dist is not None:
        wanted = targets or sorted(manifest["targets"])
        for target in wanted:
            entry = manifest["targets"].get(target)
            if entry is None:
                raise Rejected(f"target {target} is not in the manifest")
            path = Path(dist) / entry["asset"]
            if not path.is_file():
                raise Rejected(f"{target}: missing asset {path}")
            size, sha256 = file_digest(path)
            if size != entry["size"]:
                raise Rejected(f"{target}: size {size} != manifest {entry['size']} ({entry['asset']})")
            if sha256 != entry["sha256"]:
                raise Rejected(f"{target}: sha256 mismatch for {entry['asset']}")
    return manifest


# --- CLI ----------------------------------------------------------------------

def _asset(value):
    target, sep, path = value.partition("=")
    if not sep or not target or not path:
        raise argparse.ArgumentTypeError("expected <target>=<path>")
    return target, path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("key-id", help="print the key id of a .pub or .minisig file")
    p.add_argument("path")

    p = sub.add_parser("generate", help="write the canonical (unsigned) manifest")
    p.add_argument("--tag", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--key-id", required=True)
    p.add_argument("--asset", type=_asset, action="append", default=[], required=True)
    p.add_argument("--policy", default=str(DEFAULT_POLICY))
    p.add_argument("--out", required=True)

    p = sub.add_parser("trusted-comment", help="print the trusted comment to sign with")
    p.add_argument("--manifest", required=True)
    p.add_argument("--policy", default=str(DEFAULT_POLICY))
    p.add_argument("--now", type=int)

    p = sub.add_parser("verify", help="verify signature, pinned key and assets")
    p.add_argument("--manifest", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--keys-dir", default=str(DEFAULT_KEYS_DIR))
    p.add_argument("--dist")
    p.add_argument("--target", action="append", default=[])
    p.add_argument("--now", type=int)
    p.add_argument("--minisign", default=os.environ.get("MINISIGN", "minisign"))

    args = parser.parse_args(argv)
    try:
        if args.command == "key-id":
            path = Path(args.path)
            print(public_key_id(path) if path.suffix == ".pub" else parse_signature(path)[0])
        elif args.command == "generate":
            manifest = build_manifest(args.tag, args.commit, args.key_id, args.asset, load_policy(args.policy))
            Path(args.out).write_bytes(canonical_json(manifest))
        elif args.command == "trusted-comment":
            manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
            now = int(time.time()) if args.now is None else args.now
            print(trusted_comment(manifest, load_policy(args.policy), now))
        else:
            manifest = verify(args.manifest, args.signature, args.keys_dir, args.dist,
                              args.target or None, args.now, args.minisign)
            checked = ", ".join(args.target or sorted(manifest["targets"])) if args.dist else "none"
            print(f"verified {manifest['tag']} signed by {manifest['key_id']}; assets checked: {checked}")
    except Rejected as exc:
        print(f"release manifest REJECTED: {exc}", file=sys.stderr)
        return 1
    except (SystemExit, KeyboardInterrupt):
        raise
    except Exception as exc:  # noqa: BLE001 - a crash must not read as "rejected"
        print(f"release manifest ERROR (internal, not a verdict): {type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
