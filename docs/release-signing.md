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

## Where the keys live (user decision Q6)

Two key pairs exist; both secret keys live **only** in GitHub, as secrets of
the **`release` environment** (never repository or organisation secrets).
They were generated on 2026-11-23 with random passwords, set with `gh`, and
the local copies were shredded: no offline copy exists, and GitHub secrets
cannot be read back.

| Slot | Pinned public key | Key id | Environment secrets |
|---|---|---|---|
| `current` | `scripts/release/minisign/heimdall-release-1.pub` | `F0C12EB5F62E8C66` | `RELEASE_MINISIGN_SECRET_KEY`, `RELEASE_MINISIGN_PASSWORD` |
| `next` | `scripts/release/minisign/heimdall-release-2.pub` | `7D1CD02AE0E7D223` | `RELEASE_MINISIGN_NEXT_SECRET_KEY`, `RELEASE_MINISIGN_NEXT_PASSWORD` |

The `release` environment **variable** `RELEASE_MINISIGN_SIGNING_SLOT`
(`current`, the default, or `next`) picks the slot that signs. Because
secrets are write-only, rotation flips this variable rather than moving key
material between secrets.

- Only the `manifest` job references `environment: release`. It has
  `contents: read`, receives both slots but unsets the unused one, writes the
  chosen key to `$RUNNER_TEMP` with mode 0600, deletes it as soon as the
  manifest is signed, checks that its key id is pinned, and verifies.
- **Pull-request builds cannot read the keys**: environment secrets go only
  to jobs that name the environment, and the environment's deployment rules
  admit only the branch `main` and tags `v*` (a PR runs on
  `refs/pull/<n>/merge`, so a PR job naming the environment is refused). Fork
  PRs never receive secrets at all. No `pull_request_target` workflow may
  name the `release` environment.
- The job fails the release when the chosen slot's secret is missing, the
  password is wrong, or the key is not pinned. No release ships without a
  manifest.

### Recreating the environment (repository admin)

```bash
R=tanmayv/heimdall-agent-manager
gh api -X PUT repos/$R/environments/release \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/$R/environments/release/deployment-branch-policies -f name=main -f type=branch
gh api -X POST repos/$R/environments/release/deployment-branch-policies -f name='v*' -f type=tag
gh variable set RELEASE_MINISIGN_SIGNING_SLOT --env release -R $R --body current
```

Generate a key in a private directory (`umask 077`, outside the repo) with
`minisign -G -p heimdall-release-N.pub -s heimdall-release-N.key` and a
random password, then load it into a slot without printing it:

```bash
gh secret set RELEASE_MINISIGN_SECRET_KEY --env release -R $R < heimdall-release-N.key
tr -d '\n' < password-file | gh secret set RELEASE_MINISIGN_PASSWORD --env release -R $R
shred -u heimdall-release-N.key password-file
```

(Use `RELEASE_MINISIGN_NEXT_SECRET_KEY` / `RELEASE_MINISIGN_NEXT_PASSWORD`
for the `next` slot.) Commit only the `.pub` file. A dry run (**Release local
binaries** dispatched with `publish_release` off from a branch the
environment admits) must log `verified …` and `tampered bundle rejected as
expected`; the step summary shows the manifest.

## Rotation (ship the next key one release ahead)

Verifiers only trust keys pinned in the code they run, so a key must be
pinned in a release **before** any release is signed with it. The pinned set
is always two keys: the signing slot's key and the other slot's key.

Today releases pin {1, 2} and sign with slot `current` (key 1). To rotate to
key 2, only after the first release that pinned key 2 has rolled out widely
(promoted to stable and taken by the update engine):

1. Generate key 3 and load it into the **retiring** slot (`current`,
   overwriting key 1's secrets).
2. Set `RELEASE_MINISIGN_SIGNING_SLOT=next` (key 2 signs from now on).
3. In the same release, replace `heimdall-release-1.pub` with
   `heimdall-release-3.pub` (pins {2, 3}). That release is signed with key 2,
   which every install pinning {1, 2} trusts; key 3 is pinned one release
   ahead.

The following rotation mirrors it: key 4 goes into the `next` slot, the
variable goes back to `current`, and the pins become {3, 4}. Update the slot
table above each time.

A bridge whose pins predate the new signing key cannot verify the rotated
release directly; it must first update to a release that pins it (the engine
resolves the newest release it can verify).

## Revocation (key compromise)

1. Delete the compromised slot's secrets from the `release` environment at
   once (`gh secret delete … --env release`).
2. If the other slot's key is intact: switch `RELEASE_MINISIGN_SIGNING_SLOT`
   to it, load a fresh key into the compromised slot, and ship a release
   pinning {intact, fresh} (an emergency rotation in one step; installs
   already trust the intact key).
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
