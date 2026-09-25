// REQ-VAULT-ARTIFACTS-1: Unit Tests for Artifacts UI Zero-Knowledge Encryption, Decryption,
// and Reusable VaultText Integration.
//
// RUN: node --test tests/ui_artifacts_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  VAULT_ARMOR_PREFIX,
  base64ToBytes,
  bytesToBase64,
} from '../src/ui/utils/vaultContent.ts';
import {
  encryptArtifactFields,
  decryptArtifactRecord,
  decryptArtifactText,
} from '../src/ui/utils/vaultArtifacts.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DIFFERENT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// Test 1: Static verification of component files, contracts, and imports
// -----------------------------------------------------------------------------

test('Artifact UI components, endpoints, and utils exist with required contracts', () => {
  const artifactViewerFile = path.join(REPO_ROOT, 'src/ui/components/ArtifactViewer.tsx');
  const libraryPageFile = path.join(REPO_ROOT, 'src/ui/components/LibraryPage.tsx');
  const attachmentPreviewFile = path.join(REPO_ROOT, 'src/ui/components/ArtifactAttachmentPreview.tsx');
  const artifactsEndpointFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/artifacts.ts');
  const vaultArtifactsFile = path.join(REPO_ROOT, 'src/ui/utils/vaultArtifacts.ts');

  assert.ok(fs.existsSync(artifactViewerFile), 'ArtifactViewer.tsx must exist');
  assert.ok(fs.existsSync(libraryPageFile), 'LibraryPage.tsx must exist');
  assert.ok(fs.existsSync(attachmentPreviewFile), 'ArtifactAttachmentPreview.tsx must exist');
  assert.ok(fs.existsSync(artifactsEndpointFile), 'artifacts.ts must exist');
  assert.ok(fs.existsSync(vaultArtifactsFile), 'vaultArtifacts.ts must exist');

  // Verify ArtifactViewer integrates VaultText and handles title, description, content
  const viewerSrc = fs.readFileSync(artifactViewerFile, 'utf8');
  assert.ok(
    viewerSrc.includes('VaultText'),
    'ArtifactViewer.tsx must integrate VaultText component',
  );
  assert.ok(
    viewerSrc.includes('<VaultText value={title}'),
    'ArtifactViewer.tsx must render title wrapped in VaultText',
  );
  assert.ok(
    viewerSrc.includes('selectedArtifactMeta.description'),
    'ArtifactViewer.tsx must handle description field',
  );
  assert.ok(
    viewerSrc.includes('isVaultArmored'),
    'ArtifactViewer.tsx must check for armored content',
  );

  // Verify LibraryPage integrates VaultText
  const librarySrc = fs.readFileSync(libraryPageFile, 'utf8');
  assert.ok(
    librarySrc.includes('VaultText'),
    'LibraryPage.tsx must integrate VaultText component',
  );
  assert.ok(
    librarySrc.includes('<VaultText value={a?.name}'),
    'LibraryPage.tsx must wrap artifact name with VaultText',
  );

  // Verify ArtifactAttachmentPreview integrates VaultText
  const previewSrc = fs.readFileSync(attachmentPreviewFile, 'utf8');
  assert.ok(
    previewSrc.includes('VaultText'),
    'ArtifactAttachmentPreview.tsx must integrate VaultText component',
  );

  // Verify artifacts endpoint imports and uses vault encryption
  const endpointSrc = fs.readFileSync(artifactsEndpointFile, 'utf8');
  assert.ok(
    endpointSrc.includes('encryptVaultText'),
    'artifacts.ts must import and use encryptVaultText',
  );
  assert.ok(
    endpointSrc.includes('decryptVaultText'),
    'artifacts.ts must import and use decryptVaultText',
  );
  assert.ok(
    endpointSrc.includes('createArtifact'),
    'artifacts.ts must define createArtifact mutation',
  );
  assert.ok(
    endpointSrc.includes('updateArtifact'),
    'artifacts.ts must define updateArtifact mutation',
  );
  assert.ok(
    endpointSrc.includes('fetchArtifactTextContent'),
    'artifacts.ts must define fetchArtifactTextContent query',
  );
});

// -----------------------------------------------------------------------------
// Test 2: Legacy unarmored plaintext artifact tolerance and passthrough
// -----------------------------------------------------------------------------

test('Legacy plaintext artifacts pass through without error', async () => {
  const legacyArtifact = {
    artifact_id: 'art_legacy_100',
    name: 'architecture-diagram.md',
    description: 'System deployment topology for production clusters',
    content: '# Architecture Overview\nAll services connect via mTLS.',
    kind: 'markdown',
    mime: 'text/markdown',
    ext: '.md',
    size_bytes: 1024,
  };

  const unlockedDecrypted = await decryptArtifactRecord(legacyArtifact, TEST_KEY_HEX);
  assert.strictEqual(unlockedDecrypted.name, legacyArtifact.name);
  assert.strictEqual(unlockedDecrypted.description, legacyArtifact.description);
  assert.strictEqual(unlockedDecrypted.content, legacyArtifact.content);
  assert.strictEqual(unlockedDecrypted.kind, 'markdown');

  const lockedDecrypted = await decryptArtifactRecord(legacyArtifact, null);
  assert.strictEqual(lockedDecrypted.name, legacyArtifact.name);
  assert.strictEqual(lockedDecrypted.description, legacyArtifact.description);
  assert.strictEqual(lockedDecrypted.content, legacyArtifact.content);

  const plainText = 'Direct plaintext content string';
  assert.strictEqual(await decryptArtifactText(plainText, TEST_KEY_HEX), plainText);
  assert.strictEqual(await decryptArtifactText(plainText, null), plainText);
});

// -----------------------------------------------------------------------------
// Test 3: Locked vault behavior preserves armored ciphertext safely
// -----------------------------------------------------------------------------

test('Locked vault preserves armored strings without errors', async () => {
  const plaintext = 'Sensitive deployment plan artifact';
  const armored = await encryptVaultText(plaintext, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armored));
  assert.ok(armored.startsWith(VAULT_ARMOR_PREFIX));

  // Without key (locked vault):
  const lockedRecord = await decryptArtifactRecord(
    { name: armored, description: armored, content: armored },
    null,
  );
  assert.strictEqual(lockedRecord.name, armored);
  assert.strictEqual(lockedRecord.description, armored);
  assert.strictEqual(lockedRecord.content, armored);

  const lockedText = await decryptArtifactText(armored, null);
  assert.strictEqual(lockedText, armored);
});

// -----------------------------------------------------------------------------
// Test 4: encryptArtifactFields encrypts name, description, and content into vault:v1:...
// -----------------------------------------------------------------------------

test('encryptArtifactFields encrypts name, description, and content into vault:v1:<base64> when unlocked', async () => {
  const payload = {
    name: 'security-audit-report.md',
    description: 'Comprehensive pen-test report for authentication gateway',
    content: '# Pen Test Findings\nZero high-severity vulnerabilities found.',
    kind: 'markdown',
    mime: 'text/markdown',
    ext: '.md',
    project_id: 'proj_alpha_99',
    size_bytes: 2048,
  };

  const encrypted = await encryptArtifactFields(payload, TEST_KEY_HEX);

  // Metadata preserved in plaintext
  assert.strictEqual(encrypted.kind, 'markdown');
  assert.strictEqual(encrypted.mime, 'text/markdown');
  assert.strictEqual(encrypted.ext, '.md');
  assert.strictEqual(encrypted.project_id, 'proj_alpha_99');
  assert.strictEqual(encrypted.size_bytes, 2048);

  // Name, description, and content must be encrypted
  assert.notStrictEqual(encrypted.name, payload.name);
  assert.ok(isVaultArmored(encrypted.name), 'name must be armored');

  assert.notStrictEqual(encrypted.description, payload.description);
  assert.ok(isVaultArmored(encrypted.description), 'description must be armored');

  assert.notStrictEqual(encrypted.content, payload.content);
  assert.ok(isVaultArmored(encrypted.content), 'content must be armored');

  // contentBase64 is generated containing the armored ciphertext
  assert.ok(encrypted.contentBase64, 'contentBase64 must be populated');
  const decodedBase64 = new TextDecoder().decode(base64ToBytes(encrypted.contentBase64));
  assert.strictEqual(decodedBase64, encrypted.content);

  // Idempotency: re-encrypting should not double-encrypt
  const reEncrypted = await encryptArtifactFields(encrypted, TEST_KEY_HEX);
  assert.strictEqual(reEncrypted.name, encrypted.name);
  assert.strictEqual(reEncrypted.description, encrypted.description);
  assert.strictEqual(reEncrypted.content, encrypted.content);
});

// -----------------------------------------------------------------------------
// Test 5: Full round-trip encryption and decryption of Artifact records
// -----------------------------------------------------------------------------

test('Full round-trip encryption and decryption of Artifact records', async () => {
  const original = {
    artifact_id: 'art_roundtrip_456',
    name: 'database-migration-spec.sql',
    description: 'Schema definition for user credentials table',
    content: 'CREATE TABLE secret_tokens (id TEXT PRIMARY KEY, key_hash TEXT NOT NULL);',
    kind: 'sql',
    mime: 'text/x-sql',
    ext: '.sql',
    project_id: 'proj_core_01',
  };

  // 1. Encrypt
  const encrypted = await encryptArtifactFields(original, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.name));
  assert.ok(isVaultArmored(encrypted.description));
  assert.ok(isVaultArmored(encrypted.content));

  // 2. Decrypt with correct key
  const decrypted = await decryptArtifactRecord(encrypted, TEST_KEY_HEX);
  assert.strictEqual(decrypted.name, original.name);
  assert.strictEqual(decrypted.description, original.description);
  assert.strictEqual(decrypted.content, original.content);
  assert.strictEqual(decrypted.artifact_id, original.artifact_id);
  assert.strictEqual(decrypted.kind, original.kind);
  assert.strictEqual(decrypted.project_id, original.project_id);

  // 3. Decrypt content text directly
  const decryptedContent = await decryptArtifactText(encrypted.content, TEST_KEY_HEX);
  assert.strictEqual(decryptedContent, original.content);
});

// -----------------------------------------------------------------------------
// Test 6: Partial payloads and base64 content encryption
// -----------------------------------------------------------------------------

test('encryptArtifactFields handles contentBase64 when content string is omitted', async () => {
  const rawText = 'SELECT * FROM confidential_logs WHERE level = "CRITICAL";';
  const utf8Base64 = bytesToBase64(new TextEncoder().encode(rawText));

  const payload = {
    name: 'query.sql',
    contentBase64: utf8Base64,
  };

  const encrypted = await encryptArtifactFields(payload, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.name));
  assert.ok(isVaultArmored(encrypted.content));

  const decryptedFromContent = await decryptVaultText(encrypted.content!, TEST_KEY_HEX);
  assert.strictEqual(decryptedFromContent, rawText);

  // contentBase64 should decode to the armored string
  const armoredFromBase64 = new TextDecoder().decode(base64ToBytes(encrypted.contentBase64!));
  assert.strictEqual(armoredFromBase64, encrypted.content);
});
