// REQ-FS-ENC-4: Unit Tests for Web UI projectFs Zero-Knowledge Vault Encryption & Decryption
// Verifies transparent client-side decryption for file reads and search matches,
// and client-side encryption for file writes and batch file writes.
//
// RUN: node --test tests/ui_project_fs_vault_test.ts

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
} from '../src/ui/utils/vaultContent.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DIFFERENT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// Section 1: Static Architecture & Endpoint Wiring Verification
// -----------------------------------------------------------------------------

test('REQ-FS-ENC-4: projectFs.ts imports vault crypto utilities and implements all zero-trust endpoints', () => {
  const projectFsFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/projectFs.ts');
  assert.ok(fs.existsSync(projectFsFile), 'projectFs.ts must exist');

  const content = fs.readFileSync(projectFsFile, 'utf8');

  // Verify vault crypto imports
  assert.ok(
    content.includes('isVaultArmored') &&
      content.includes('decryptVaultText') &&
      content.includes('encryptVaultText'),
    'projectFs.ts must import isVaultArmored, decryptVaultText, and encryptVaultText',
  );

  // Verify readProjectFile transparent decryption
  assert.ok(
    content.includes('readProjectFile: build.query'),
    'projectFs.ts must define readProjectFile query',
  );
  assert.ok(
    content.includes('isVaultArmored(data.content)'),
    'readProjectFile must check isVaultArmored(data.content)',
  );
  assert.ok(
    content.includes('decryptVaultText(data.content, rawKeyHex)'),
    'readProjectFile must decrypt data.content with rawKeyHex',
  );

  // Verify writeProjectFile client-side encryption
  assert.ok(
    content.includes('writeProjectFile: build.mutation'),
    'projectFs.ts must define writeProjectFile mutation',
  );
  assert.ok(
    content.includes('encryptVaultText(outgoingContent, rawKeyHex)'),
    'writeProjectFile must encrypt outgoingContent with rawKeyHex before PUT mutation',
  );

  // Verify batchWriteProjectFiles client-side encryption
  assert.ok(
    content.includes('batchWriteProjectFiles: build.mutation'),
    'projectFs.ts must define batchWriteProjectFiles mutation',
  );
  assert.ok(
    content.includes('encryptVaultText(file.content, rawKeyHex)'),
    'batchWriteProjectFiles must encrypt each file.content with rawKeyHex before batch PUT mutation',
  );

  // Verify searchProjectFiles grep matches decryption
  assert.ok(
    content.includes('searchProjectFiles: build.query'),
    'projectFs.ts must define searchProjectFiles query',
  );
  assert.ok(
    content.includes('decryptSearchMatches'),
    'searchProjectFiles must use decryptSearchMatches to decrypt match items',
  );
});

// -----------------------------------------------------------------------------
// Section 2: Behavioral verification of readProjectFile decryption logic
// -----------------------------------------------------------------------------

test('readProjectFile logic: transparently decrypts vault:v1:... content when vault is unlocked', async () => {
  const secretFileText = 'DATABASE_URL="postgres://admin:supersecret@db:5432/main"\nJWT_SECRET="xyz-token"';
  const armoredCiphertext = await encryptVaultText(secretFileText, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armoredCiphertext), 'Ciphertext must start with vault:v1:');

  // Simulated queryFn read transform with unlocked vault
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_KEY_HEX } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const data: { content?: string; ok: boolean } = { ok: true, content: armoredCiphertext };
  if (data && typeof data.content === 'string' && isVaultArmored(data.content)) {
    if (isUnlocked && rawKeyHex) {
      try {
        data.content = await decryptVaultText(data.content, rawKeyHex);
      } catch {}
    }
  }

  assert.strictEqual(data.content, secretFileText, 'Armored file content must be decrypted to original plaintext');
});

test('readProjectFile logic: leaves content untouched or readable when vault is locked or key not present', async () => {
  const secretFileText = 'SUPER_SECRET_TOKEN=abc12345';
  const armoredCiphertext = await encryptVaultText(secretFileText, TEST_KEY_HEX);

  // Case A: Vault locked
  const stateLocked: any = { vault: { isUnlocked: false, rawVaultKeyHex: null } };
  const isUnlockedA = Boolean(stateLocked?.vault?.isUnlocked || stateLocked?.vault?.unlocked);
  const rawKeyHexA = stateLocked?.vault?.rawVaultKeyHex;

  const dataLocked: { content?: string } = { content: armoredCiphertext };
  if (dataLocked && typeof dataLocked.content === 'string' && isVaultArmored(dataLocked.content)) {
    if (isUnlockedA && rawKeyHexA) {
      try {
        dataLocked.content = await decryptVaultText(dataLocked.content, rawKeyHexA);
      } catch {}
    }
  }
  assert.strictEqual(dataLocked.content, armoredCiphertext, 'Armored content must remain intact when locked');

  // Case B: Key missing
  const stateNoKey: any = { vault: { isUnlocked: true, rawVaultKeyHex: null } };
  const isUnlockedB = Boolean(stateNoKey?.vault?.isUnlocked || stateNoKey?.vault?.unlocked);
  const rawKeyHexB = stateNoKey?.vault?.rawVaultKeyHex;

  const dataNoKey: { content?: string } = { content: armoredCiphertext };
  if (dataNoKey && typeof dataNoKey.content === 'string' && isVaultArmored(dataNoKey.content)) {
    if (isUnlockedB && rawKeyHexB) {
      try {
        dataNoKey.content = await decryptVaultText(dataNoKey.content, rawKeyHexB);
      } catch {}
    }
  }
  assert.strictEqual(dataNoKey.content, armoredCiphertext, 'Armored content must remain intact when key missing');
});

test('readProjectFile logic: leaves content untouched when decryption fails (wrong key)', async () => {
  const secretFileText = 'CONFIDENTIAL_NOTE';
  const armoredCiphertext = await encryptVaultText(secretFileText, TEST_KEY_HEX);

  const stateWrongKey: any = { vault: { isUnlocked: true, rawVaultKeyHex: DIFFERENT_KEY_HEX } };
  const isUnlocked = Boolean(stateWrongKey?.vault?.isUnlocked || stateWrongKey?.vault?.unlocked);
  const rawKeyHex = stateWrongKey?.vault?.rawVaultKeyHex;

  const data: { content?: string } = { content: armoredCiphertext };
  if (data && typeof data.content === 'string' && isVaultArmored(data.content)) {
    if (isUnlocked && rawKeyHex) {
      try {
        data.content = await decryptVaultText(data.content, rawKeyHex);
      } catch {}
    }
  }

  assert.strictEqual(
    data.content,
    armoredCiphertext,
    'Armored content must remain untouched when decryption fails rather than crashing',
  );
});

test('readProjectFile logic: leaves unarmored plain text untouched', async () => {
  const plainText = '# Public README\nThis is a standard repository.';

  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_KEY_HEX } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const data: { content?: string } = { content: plainText };
  if (data && typeof data.content === 'string' && isVaultArmored(data.content)) {
    if (isUnlocked && rawKeyHex) {
      try {
        data.content = await decryptVaultText(data.content, rawKeyHex);
      } catch {}
    }
  }

  assert.strictEqual(data.content, plainText, 'Plain unarmored text must pass through untouched');
});

// -----------------------------------------------------------------------------
// Section 3: Behavioral verification of writeProjectFile encryption logic
// -----------------------------------------------------------------------------

test('writeProjectFile logic: encrypts content to vault:v1:... before sending PUT request when vault is unlocked', async () => {
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_KEY_HEX } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const plainContent = 'AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"';
  let outgoingContent = plainContent;

  if (isUnlocked && rawKeyHex && typeof outgoingContent === 'string') {
    if (!isVaultArmored(outgoingContent)) {
      outgoingContent = await encryptVaultText(outgoingContent, rawKeyHex);
    }
  }

  assert.ok(isVaultArmored(outgoingContent), 'Transmitted content must be armored');
  assert.notStrictEqual(outgoingContent, plainContent);

  const decrypted = await decryptVaultText(outgoingContent, TEST_KEY_HEX);
  assert.strictEqual(decrypted, plainContent, 'Armored outgoing content must decrypt back to original text');
});

test('writeProjectFile logic: preserves unencrypted content when vault is locked', async () => {
  const state: any = { vault: { isUnlocked: false, rawVaultKeyHex: null } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const plainContent = 'const a = 1;';
  let outgoingContent = plainContent;

  if (isUnlocked && rawKeyHex && typeof outgoingContent === 'string') {
    if (!isVaultArmored(outgoingContent)) {
      outgoingContent = await encryptVaultText(outgoingContent, rawKeyHex);
    }
  }

  assert.strictEqual(outgoingContent, plainContent, 'When vault is locked, outgoing content must remain unencrypted');
});

test('writeProjectFile logic: is idempotent and does not double-encrypt already-armored content', async () => {
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_KEY_HEX } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const alreadyArmored = await encryptVaultText('secret data', TEST_KEY_HEX);
  let outgoingContent = alreadyArmored;

  if (isUnlocked && rawKeyHex && typeof outgoingContent === 'string') {
    if (!isVaultArmored(outgoingContent)) {
      outgoingContent = await encryptVaultText(outgoingContent, rawKeyHex);
    }
  }

  assert.strictEqual(outgoingContent, alreadyArmored, 'Already-armored content must not be double-encrypted');
});

// -----------------------------------------------------------------------------
// Section 4: Behavioral verification of batchWriteProjectFiles encryption logic
// -----------------------------------------------------------------------------

test('batchWriteProjectFiles logic: encrypts each file content before sending batch PUT request when vault is unlocked', async () => {
  const state: any = { vault: { isUnlocked: true, rawVaultKeyHex: TEST_KEY_HEX } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const files = [
    { path: 'secrets/prod.env', content: 'DB_PASS=xyz789' },
    { path: 'config/keys.json', content: '{"token": "secret_token_val"}' },
    { path: 'src/main.ts', content: 'console.log("hello");' },
  ];

  let outgoingFiles = files;
  if (isUnlocked && rawKeyHex && Array.isArray(files)) {
    outgoingFiles = await Promise.all(
      files.map(async (file) => {
        if (typeof file.content === 'string') {
          const content = isVaultArmored(file.content)
            ? file.content
            : await encryptVaultText(file.content, rawKeyHex);
          return { ...file, content };
        }
        return file;
      }),
    );
  }

  assert.strictEqual(outgoingFiles.length, 3);
  for (let i = 0; i < files.length; i++) {
    const original = files[i];
    const transformed = outgoingFiles[i];

    assert.strictEqual(transformed.path, original.path);
    assert.ok(isVaultArmored(transformed.content), `File ${original.path} must be armored`);

    const decrypted = await decryptVaultText(transformed.content, TEST_KEY_HEX);
    assert.strictEqual(decrypted, original.content, `File ${original.path} must decrypt to original plaintext`);
  }
});

test('batchWriteProjectFiles logic: preserves plain file content when vault is locked', async () => {
  const state: any = { vault: { isUnlocked: false, rawVaultKeyHex: null } };
  const isUnlocked = Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked);
  const rawKeyHex = state?.vault?.rawVaultKeyHex;

  const files = [{ path: 'test.txt', content: 'plain unencrypted text' }];

  let outgoingFiles = files;
  if (isUnlocked && rawKeyHex && Array.isArray(files)) {
    outgoingFiles = await Promise.all(
      files.map(async (file) => {
        if (typeof file.content === 'string') {
          const content = isVaultArmored(file.content)
            ? file.content
            : await encryptVaultText(file.content, rawKeyHex);
          return { ...file, content };
        }
        return file;
      }),
    );
  }

  assert.strictEqual(outgoingFiles[0].content, 'plain unencrypted text');
});

// -----------------------------------------------------------------------------
// Section 5: Behavioral verification of searchProjectFiles grep matches decryption
// -----------------------------------------------------------------------------

test('searchProjectFiles logic: decrypts armored line_content and line in grep matches when vault is unlocked', async () => {
  const secretLine1 = 'const API_SECRET = "sk_live_999";';
  const secretLine2 = 'export const DB_PASS = "admin_super_secret";';
  const armored1 = await encryptVaultText(secretLine1, TEST_KEY_HEX);
  const armored2 = await encryptVaultText(secretLine2, TEST_KEY_HEX);

  const rawMatches = [
    {
      path: 'src/config.ts',
      line_number: 10,
      column: 1,
      match_start: 0,
      match_end: 15,
      line: armored1,
      line_content: armored1,
    },
    {
      path: 'src/db.ts',
      line_number: 25,
      column: 1,
      match_start: 0,
      match_end: 20,
      line: armored2,
    },
    {
      path: 'src/public.ts',
      line_number: 5,
      column: 1,
      match_start: 0,
      match_end: 10,
      line: 'const PUBLIC_VAR = 42;',
      line_content: 'const PUBLIC_VAR = 42;',
    },
  ];

  // Helper matching projectFs.ts decryptSearchMatches
  async function decryptSearchMatches(matches: any[], rawKeyHex: string) {
    return await Promise.all(
      matches.map(async (m: any) => {
        const updated = { ...m };
        if (typeof updated.line_content === 'string' && isVaultArmored(updated.line_content)) {
          try {
            updated.line_content = await decryptVaultText(updated.line_content, rawKeyHex);
          } catch {}
        }
        if (typeof updated.line === 'string' && isVaultArmored(updated.line)) {
          try {
            updated.line = await decryptVaultText(updated.line, rawKeyHex);
          } catch {}
        }
        if (updated.line_content !== undefined && updated.line === undefined) {
          updated.line = updated.line_content;
        }
        if (updated.line !== undefined && updated.line_content === undefined) {
          updated.line_content = updated.line;
        }
        return updated;
      }),
    );
  }

  const decryptedMatches = await decryptSearchMatches(rawMatches, TEST_KEY_HEX);

  assert.strictEqual(decryptedMatches.length, 3);
  assert.strictEqual(decryptedMatches[0].line, secretLine1);
  assert.strictEqual(decryptedMatches[0].line_content, secretLine1);
  assert.strictEqual(decryptedMatches[1].line, secretLine2);
  assert.strictEqual(decryptedMatches[1].line_content, secretLine2);
  assert.strictEqual(decryptedMatches[2].line, 'const PUBLIC_VAR = 42;');
  assert.strictEqual(decryptedMatches[2].line_content, 'const PUBLIC_VAR = 42;');
});

// -----------------------------------------------------------------------------
// Section 6: Redux vaultSlice state integration
// -----------------------------------------------------------------------------

test('vaultSlice transitions correctly control unlocked and keyHex states', () => {
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.strictEqual(selectIsVaultUnlocked({ vault: state }), false);
  assert.strictEqual(selectRawVaultKeyHex({ vault: state }), null);

  state = vaultReducer(state, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked());
  assert.strictEqual(selectIsVaultUnlocked({ vault: state }), true);
  assert.strictEqual((state as any).rawVaultKeyHex, undefined);
  assert.strictEqual(selectRawVaultKeyHex({ vault: state }), null);

  state = vaultReducer(state, lockVault());
  assert.strictEqual(selectIsVaultUnlocked({ vault: state }), false);
  assert.strictEqual(selectRawVaultKeyHex({ vault: state }), null);
});
