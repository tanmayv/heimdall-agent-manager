# Release signing: the minisign release manifest

Every release built by **Release local binaries**
(`.github/workflows/release-local-binaries.yml`) carries two extra assets:

| Asset | What it is |
|---|---|
| `heimdall-release-manifest.json` | Canonical JSON (sorted keys, no extra whitespace, trailing LF) naming the release and every bridge bundle |
| `heimdall-release-manifest.json.minisig` | Its [minisign](https://jedisct1.github.io/minisign/) signature (Ed25519, prehashed) |

`SHA256SUMS` is still published for people checking a download by hand. It is
not signed and is **not** a trust anchor; the manifest is.

## Manifest format (schema 1)

```json
{
  "kind": "heimdall-release-manifest",
  "schema": 1,
  "tag": "v0.5.75",
  "version": "0.5.75",
  "commit": "<40-hex release commit>",
  "key_id": "<16-hex minisign key id that signed it>",
  "min_engine": 0,
  "journal_schema": 0,
  "targets": {
    "linux-amd64": {"asset": "heimdall-local-linux-amd64-v0.5.75.tar.gz", "size": 12345678, "sha256": "<64-hex>"},
    "windows-amd64": {"asset": "heimdall-local-windows-amd64-v0.5.75.zip", "size": 12345678, "sha256": "<64-hex>"}
  }
}
```

- `targets` lists every bridge bundle of the release (`darwin-arm64`,
  `linux-amd64`, `linux-arm64`, `windows-amd64`, and `darwin-amd64` when the
  Intel build is enabled). `asset` is the published file name, never a path.
- `min_engine` (oldest update engine allowed to install this release) and
  `journal_schema` (the journal schema this release writes) come from
  `scripts/release/minisign/manifest-policy.json`. Both are `0` ("no
  supervisor engine yet") until the engine spec (T9) defines real values; bump
  them in that file in the commit that changes them.
- The signature's **trusted comment** (covered by the signature) is
  `{"expires":<unix>,"seq":<unix>,"version":"<tag>"}`. `seq` is the signing
  time, so a later signature always has a larger `seq` (rollback defence);
  `expires` is `seq + expires_after_days` from the policy file (365 days;
  freeze defence). What an engine does with an expired manifest of an older,
  already-installed release is the engine spec's decision.

## Verifying

```bash
python3 -I scripts/release/release-manifest.py verify \
  --manifest heimdall-release-manifest.json \
  --signature heimdall-release-manifest.json.minisig \
  --dist <dir with the downloaded bundles> [--target linux-amd64]
```

It fails closed (exit 1) unless, in this order: the signature's key id is one
of the keys pinned in `scripts/release/minisign/*.pub`; `minisign -V` accepts
the signature and trusted comment with that key; the manifest is canonical and
names the same key id and the tag in the trusted comment; it has not expired;
and each checked bundle has exactly the listed size and SHA-256. Installers and
the update engine must apply the same rules (T3b, T12).

## Where the key lives (user decision Q6)

- The **secret key** is the GitHub Actions secret
  `RELEASE_MINISIGN_SECRET_KEY` (the full two-line `.key` file) in the
  **`release` environment**, with its password in `RELEASE_MINISIGN_PASSWORD`
  in the same environment. It is never a repository or organisation secret.
- Only the `manifest` job references `environment: release`. It has
  `contents: read`, writes the key to `$RUNNER_TEMP` with mode 0600, deletes
  it as soon as the manifest is signed, and verifies with the pinned keys.
- **Pull-request builds cannot read it**: environment secrets are only given
  to jobs that name the environment, the environment's deployment rule admits
  only `main` and `v*` tags (a PR runs on `refs/pull/<n>/merge`, so a job that
  names the environment from a PR is refused), and fork PRs never receive
  secrets at all. No `pull_request_target` workflow may name the `release`
  environment.
- The job fails the release when the secret is missing, the password is wrong,
  or the key is not pinned. Releases cannot ship without a manifest.

### One-time setup (repository admin)

1. Generate two key pairs on a trusted machine (`minisign` ≥ 0.10):
   ```bash
   minisign -G -p heimdall-release-1.pub -s heimdall-release-1.key
   minisign -G -p heimdall-release-2.pub -s heimdall-release-2.key
   ```
   Use a strong, different password for each. Key 1 signs now; key 2 is the
   next key. Store both `.key` files and passwords offline (password manager
   plus an offline backup). Never commit a `.key` file.
2. Commit both `.pub` files to `scripts/release/minisign/` (exactly two pinned
   keys; `test_release_manifest.py` enforces this).
3. Create the environment: *Settings → Environments → New environment*
   `release`. Under *Deployment branches and tags* choose *Selected branches
   and tags* and add the branch `main` and the tag pattern `v*`. Optionally add
   required reviewers (every release run, including dry runs, then waits for
   approval).
4. Add environment secrets `RELEASE_MINISIGN_SECRET_KEY` (contents of
   `heimdall-release-1.key`) and `RELEASE_MINISIGN_PASSWORD`. With the GitHub
   CLI: `gh secret set RELEASE_MINISIGN_SECRET_KEY --env release < heimdall-release-1.key`
   and `gh secret set RELEASE_MINISIGN_PASSWORD --env release`.
5. Dry run: dispatch **Release local binaries** with `publish_release` off.
   The `manifest` job must log `verified …` and `tampered bundle rejected as
   expected`, and its step summary shows the manifest.

## Rotation (ship the next key one release ahead)

Verifiers only trust keys pinned in the code they are running, so a new key
must be pinned in a release **before** any release is signed with it.

Pinned set: always two keys, *current* (signs releases) and *next*. The first
releases pin {1, 2} and are signed with key 1, so key 2 is trusted before it
is ever used. To rotate from key 1 to key 2:

1. Generate key 3 offline (as above).
2. Release M: set `RELEASE_MINISIGN_SECRET_KEY` / `RELEASE_MINISIGN_PASSWORD`
   to key 2, and replace `heimdall-release-1.pub` with `heimdall-release-3.pub`
   in `scripts/release/minisign/` (pins {2, 3}). Every install that pinned
   {1, 2} trusts release M; key 3 is again pinned one release ahead.
3. Archive key 1 offline (or destroy it) once release M is out.

Rotate only after the release that first pinned the next key has rolled out
widely (promoted to stable and taken by the update engine).

A bridge whose pins predate the next key cannot verify release M directly;
it must first update to a release that pins it (the engine resolves the newest release it can verify).

## Revocation (key compromise)

1. Remove the compromised key's secret from the `release` environment at once.
2. If the **next** key is intact: sign the next release with it and pin
   {next, new next}, dropping the compromised key (an emergency rotation in
   one step; installs from release N onwards already trust *next*).
3. If **both** keys are compromised, no signed path remains: ship a release
   with new pins and reinstall bridges with the install script (the release
   manifest is the root of trust; there is no higher key).
4. Delete or mark releases signed with the compromised key after the
   compromise time, and record the incident in `docs/incidents/`.

## Local test

```bash
nix shell nixpkgs#minisign -c python3 -I scripts/release/test_release_manifest.py -v
```

It signs with ephemeral keys and checks that a valid manifest verifies (with
either pinned key, including a password-protected key fed on stdin) and that a
tampered or truncated bundle, edited manifest, edited trusted comment,
unpinned key, mismatched key id, wrong tag, expired manifest and empty pin set
are each rejected.
