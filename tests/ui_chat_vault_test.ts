// REQ-VAULT-CHAT-1: Unit Tests for Chat and Conversations UI Zero-Knowledge Encryption,
// Decryption, Reusable VaultText Integration, and Legacy Plaintext Compatibility.
//
// RUN: node --test tests/ui_chat_vault_test.ts

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
import {
  resolveVaultText,
  decryptVaultTextContent,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptChatFields,
  decryptChatMessage,
  decryptChatMessages,
  encryptConversationFields,
  decryptConversationRecord,
  decryptConversationList,
} from '../src/ui/utils/vaultChats.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DIFFERENT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// Test 1: Static verification of component files, contracts, and imports
// -----------------------------------------------------------------------------

test('Chat UI components, endpoints, and utils exist with required contracts', () => {
  const chatPaneFile = path.join(REPO_ROOT, 'src/ui/components/chat/ChatPane.tsx');
  const messageItemFile = path.join(REPO_ROOT, 'src/ui/components/chat/MessageItem.tsx');
  const chatInboxFile = path.join(REPO_ROOT, 'src/ui/components/chat/ChatInbox.tsx');
  const chatMessageListFile = path.join(REPO_ROOT, 'src/ui/components/chat/ChatMessageList.tsx');
  const conversationThreadFile = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');
  const conversationsHomeFile = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationsHomePage.tsx');
  const chatsEndpointFile = path.join(REPO_ROOT, 'src/ui/api/endpoints/chats.ts');
  const vaultChatsFile = path.join(REPO_ROOT, 'src/ui/utils/vaultChats.ts');

  assert.ok(fs.existsSync(chatPaneFile), 'ChatPane.tsx must exist');
  assert.ok(fs.existsSync(messageItemFile), 'MessageItem.tsx must exist');
  assert.ok(fs.existsSync(chatInboxFile), 'ChatInbox.tsx must exist');
  assert.ok(fs.existsSync(chatMessageListFile), 'ChatMessageList.tsx must exist');
  assert.ok(fs.existsSync(conversationThreadFile), 'ConversationThreadPage.tsx must exist');
  assert.ok(fs.existsSync(conversationsHomeFile), 'ConversationsHomePage.tsx must exist');
  assert.ok(fs.existsSync(chatsEndpointFile), 'chats.ts must exist');
  assert.ok(fs.existsSync(vaultChatsFile), 'vaultChats.ts must exist');

  // Verify ChatPane integrates VaultText
  const chatPaneSrc = fs.readFileSync(chatPaneFile, 'utf8');
  assert.ok(
    chatPaneSrc.includes('VaultText'),
    'ChatPane.tsx must integrate VaultText component',
  );
  assert.ok(
    chatPaneSrc.includes('MessageItem'),
    'ChatPane.tsx must render MessageItem components',
  );

  // Verify MessageItem integrates VaultText and decryption
  const messageItemSrc = fs.readFileSync(messageItemFile, 'utf8');
  assert.ok(
    messageItemSrc.includes('VaultText'),
    'MessageItem.tsx must integrate VaultText component',
  );
  assert.ok(
    messageItemSrc.includes('isVaultArmored'),
    'MessageItem.tsx must detect vault-armored text',
  );

  // Verify ChatInbox integrates VaultText
  const chatInboxSrc = fs.readFileSync(chatInboxFile, 'utf8');
  assert.ok(
    chatInboxSrc.includes('VaultText'),
    'ChatInbox.tsx must integrate VaultText component',
  );

  // Verify ChatMessageList integrates VaultText
  const chatMessageListSrc = fs.readFileSync(chatMessageListFile, 'utf8');
  assert.ok(
    chatMessageListSrc.includes('VaultText'),
    'ChatMessageList.tsx must integrate VaultText component',
  );

  // Verify ConversationThreadPage integrates VaultText
  const conversationThreadSrc = fs.readFileSync(conversationThreadFile, 'utf8');
  assert.ok(
    conversationThreadSrc.includes('VaultText'),
    'ConversationThreadPage.tsx must integrate VaultText component',
  );

  // Verify ConversationsHomePage integrates VaultText
  const conversationsHomeSrc = fs.readFileSync(conversationsHomeFile, 'utf8');
  assert.ok(
    conversationsHomeSrc.includes('VaultText'),
    'ConversationsHomePage.tsx must integrate VaultText component',
  );

  // Verify chats.ts endpoint exports vault helpers and encrypts mutations
  const chatsEndpointSrc = fs.readFileSync(chatsEndpointFile, 'utf8');
  assert.ok(
    chatsEndpointSrc.includes('encryptVaultText'),
    'chats.ts must import and use encryptVaultText',
  );
  assert.ok(
    chatsEndpointSrc.includes('sendConversationMessage'),
    'chats.ts must define sendConversationMessage mutation',
  );
  assert.ok(
    chatsEndpointSrc.includes('updateConversationTitle'),
    'chats.ts must define updateConversationTitle mutation',
  );
  assert.ok(
    chatsEndpointSrc.includes('encryptChatFields'),
    'chats.ts must re-export encryptChatFields',
  );
});

// -----------------------------------------------------------------------------
// Test 2: Chat message body encryption and decryption round-trip
// -----------------------------------------------------------------------------

test('encryptChatFields encrypts message body when key is provided', async () => {
  const origBody = 'Confidential message: system migration scheduled at 02:00 UTC.';
  const payload = { body: origBody, author: 'user' };

  const encrypted = await encryptChatFields(payload, TEST_KEY_HEX);

  assert.equal(encrypted.author, 'user', 'author metadata must remain unaltered');
  assert.ok(encrypted.body !== origBody, 'body must not leak plaintext');
  assert.ok(isVaultArmored(encrypted.body), 'body must start with vault:v1:');

  // Round-trip decrypt
  const decrypted = await decryptChatMessage(encrypted, TEST_KEY_HEX);
  assert.equal(decrypted.body, origBody, 'body must decrypt to original plaintext');
});

test('encryptChatFields leaves body as plaintext when key is not provided', async () => {
  const origBody = 'Normal unencrypted message.';
  const payload = { body: origBody, author: 'agent' };

  const resNull = await encryptChatFields(payload, null);
  assert.equal(resNull.body, origBody, 'body must remain plaintext when key is null');
  assert.ok(!isVaultArmored(resNull.body), 'must not be armored');

  const resEmpty = await encryptChatFields(payload, '');
  assert.equal(resEmpty.body, origBody, 'body must remain plaintext when key is empty');
});

test('decryptChatMessage handles locked vault and wrong key gracefully', async () => {
  const origBody = 'Protected secret message.';
  const encrypted = await encryptChatFields({ body: origBody }, TEST_KEY_HEX);

  // When vault is locked (no key), returns armored string intact
  const lockedRes = await decryptChatMessage(encrypted, null);
  assert.equal(lockedRes.body, encrypted.body, 'locked vault must preserve armored text intact');

  // When wrong key is used, decryption error is caught gracefully
  const wrongKeyRes = await decryptChatMessage(encrypted, DIFFERENT_KEY_HEX);
  assert.equal(wrongKeyRes.body, encrypted.body, 'wrong key must return armored text intact');
});

test('decryptChatMessages decrypts an array of messages', async () => {
  const msg1 = 'First encrypted chat message';
  const msg2 = 'Second encrypted chat message';
  const enc1 = await encryptChatFields({ id: '1', body: msg1 }, TEST_KEY_HEX);
  const enc2 = await encryptChatFields({ id: '2', body: msg2 }, TEST_KEY_HEX);

  const decryptedList = await decryptChatMessages([enc1, enc2], TEST_KEY_HEX);
  assert.equal(decryptedList[0].body, msg1);
  assert.equal(decryptedList[1].body, msg2);
});

// -----------------------------------------------------------------------------
// Test 3: Conversation title and preview encryption and decryption round-trip
// -----------------------------------------------------------------------------

test('encryptConversationFields encrypts title when key is provided', async () => {
  const origTitle = 'Confidential Architecture Discussion';
  const conv = { conversationId: 'chat_123', title: origTitle };

  const encrypted = await encryptConversationFields(conv, TEST_KEY_HEX);
  assert.equal(encrypted.conversationId, 'chat_123', 'conversationId must remain plaintext');
  assert.ok(encrypted.title !== origTitle, 'title must not leak plaintext');
  assert.ok(isVaultArmored(encrypted.title), 'title must be armored');

  // Round-trip decrypt
  const decrypted = await decryptConversationRecord(encrypted, TEST_KEY_HEX);
  assert.equal(decrypted.title, origTitle, 'title must decrypt to original plaintext');
});

test('decryptConversationRecord decrypts title and previews', async () => {
  const origTitle = 'Zero-Knowledge Vault Thread';
  const origPreview = 'Last preview: keys configured successfully';
  const encTitle = await encryptVaultText(origTitle, TEST_KEY_HEX);
  const encPreview = await encryptVaultText(origPreview, TEST_KEY_HEX);

  const conv = {
    conversationId: 'chat_456',
    title: encTitle,
    last_message_preview: encPreview,
    lastMessagePreview: encPreview,
  };

  const decrypted = await decryptConversationRecord(conv, TEST_KEY_HEX);
  assert.equal(decrypted.title, origTitle);
  assert.equal(decrypted.last_message_preview, origPreview);
  assert.equal(decrypted.lastMessagePreview, origPreview);
});

test('decryptConversationList decrypts array of conversations', async () => {
  const encTitle1 = await encryptVaultText('Thread Alpha', TEST_KEY_HEX);
  const encTitle2 = await encryptVaultText('Thread Beta', TEST_KEY_HEX);

  const list = [
    { conversationId: 'c1', title: encTitle1 },
    { conversationId: 'c2', title: encTitle2 },
  ];

  const decryptedList = await decryptConversationList(list, TEST_KEY_HEX);
  assert.equal(decryptedList[0].title, 'Thread Alpha');
  assert.equal(decryptedList[1].title, 'Thread Beta');
});

// -----------------------------------------------------------------------------
// Test 4: resolveVaultText helper integration with chat values
// -----------------------------------------------------------------------------

test('resolveVaultText resolves chat messages based on vault lock state', async () => {
  const origText = 'Live chat status message.';
  const armored = await encryptVaultText(origText, TEST_KEY_HEX);

  // Plaintext returns immediately
  const resPlain = resolveVaultText(origText, false);
  assert.equal(resPlain.mode, 'plaintext');
  assert.equal(resPlain.displayText, origText);
  assert.equal(resPlain.isLocked, false);

  // Armored with vault locked returns locked status
  const resLocked = resolveVaultText(armored, false);
  assert.equal(resLocked.mode, 'locked');
  assert.ok(resLocked.isLocked);
  assert.ok(resLocked.displayText.includes('Encrypted content'));

  // Armored with vault unlocked
  const resUnlocked = resolveVaultText(armored, true);
  assert.equal(resUnlocked.mode, 'unlocked');
  assert.equal(resUnlocked.isLocked, false);

  // Async decrypt helper
  const dec = await decryptVaultTextContent(armored, TEST_KEY_HEX);
  assert.equal(dec, origText);
});

// -----------------------------------------------------------------------------
// Test 5: Legacy unarmored plaintext chat messages render transparently
// -----------------------------------------------------------------------------

test('legacy plaintext chat messages and threads render transparently without regression', async () => {
  const legacyBody = 'Legacy plaintext message from v1 system.';
  const legacyTitle = 'Legacy Thread Title';
  const legacyPreview = 'Legacy message preview snippet.';

  const message = { id: 'msg_legacy', body: legacyBody };
  const conv = {
    conversationId: 'chat_legacy',
    title: legacyTitle,
    last_message_preview: legacyPreview,
  };

  // Decryption with vault unlocked preserves plaintext
  const decMsgUnlocked = await decryptChatMessage(message, TEST_KEY_HEX);
  assert.equal(decMsgUnlocked.body, legacyBody);

  const decConvUnlocked = await decryptConversationRecord(conv, TEST_KEY_HEX);
  assert.equal(decConvUnlocked.title, legacyTitle);
  assert.equal(decConvUnlocked.last_message_preview, legacyPreview);

  // Decryption with vault locked preserves plaintext
  const decMsgLocked = await decryptChatMessage(message, null);
  assert.equal(decMsgLocked.body, legacyBody);

  const decConvLocked = await decryptConversationRecord(conv, null);
  assert.equal(decConvLocked.title, legacyTitle);
  assert.equal(decConvLocked.last_message_preview, legacyPreview);
});

// -----------------------------------------------------------------------------
// Test 6: Embedded ciphertext tokens in messages, action notices, and sender-prefixed previews (REQ-INDIRECT-DECRYPT-UI-1)
// -----------------------------------------------------------------------------

test('embedded ciphertext tokens in message bodies and sender-prefixed previews decrypt cleanly', async () => {
  const secretBody = 'I deployed the auth module successfully.';
  const armoredSecret = await encryptVaultText(secretBody, TEST_KEY_HEX);

  // Embedded token in message body
  const embeddedMsg = {
    id: 'msg_embedded',
    body: `Execution report: ${armoredSecret} (verified).`,
  };
  const decryptedMsg = await decryptChatMessage(embeddedMsg, TEST_KEY_HEX);
  assert.equal(decryptedMsg.body, `Execution report: ${secretBody} (verified).`);

  // Sender-prefixed preview: "You: vault:v1:..."
  const convWithPrefix = {
    conversationId: 'chat_prefix',
    title: 'Deployment Chat',
    lastMessagePreview: `You: ${armoredSecret}`,
    last_message_preview: `You: ${armoredSecret}`,
  };
  const decryptedConv = await decryptConversationRecord(convWithPrefix, TEST_KEY_HEX);
  assert.equal(decryptedConv.lastMessagePreview, `You: ${secretBody}`);
  assert.equal(decryptedConv.last_message_preview, `You: ${secretBody}`);

  // Action receipt with embedded token
  const actionReceiptMsg = {
    id: 'msg_action_receipt',
    body: `Action receipt for approval ${armoredSecret}`,
  };
  const decryptedActionMsg = await decryptChatMessage(actionReceiptMsg, TEST_KEY_HEX);
  assert.equal(decryptedActionMsg.body, `Action receipt for approval ${secretBody}`);
});

// -----------------------------------------------------------------------------
// Test 7: Static UI surface checks for Batches 1-4 contracts
// -----------------------------------------------------------------------------

test('UI Batches 1-4 contracts and integration adhere to specifications', () => {
  const convThreadFile = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationThreadPage.tsx');
  const convThreadSrc = fs.readFileSync(convThreadFile, 'utf8');

  // Breadcrumb projectName wrapped with VaultText
  assert.ok(
    convThreadSrc.includes('<VaultText value={projectName} fallback="Project" />'),
    'ConversationThreadPage.tsx must wrap breadcrumb projectName in VaultText',
  );

  // Composer chip wrapped with VaultText
  assert.ok(
    convThreadSrc.includes('conversation-composer-project-chip'),
    'ConversationThreadPage.tsx must have conversation-composer-project-chip',
  );

  // Overflow details menu resolves IDs to friendly names/titles
  assert.ok(
    convThreadSrc.includes('conversation-thread-overflow-details'),
    'ConversationThreadPage.tsx must render conversation-thread-overflow-details',
  );
  assert.ok(
    convThreadSrc.includes('agentDisplayName'),
    'ConversationThreadPage.tsx must resolve agent display name in details menu',
  );
  assert.ok(
    convThreadSrc.includes('chainTitle'),
    'ConversationThreadPage.tsx must resolve chain title in details menu',
  );

  // CurrentTaskStrip human display names and criteria unsuppression
  const currentTaskStripFile = path.join(REPO_ROOT, 'src/ui/components/chat/CurrentTaskStrip.tsx');
  const currentTaskStripSrc = fs.readFileSync(currentTaskStripFile, 'utf8');
  assert.ok(
    currentTaskStripSrc.includes('assigneeDisplayName'),
    'CurrentTaskStrip.tsx must compute assigneeDisplayName',
  );
  assert.ok(
    currentTaskStripSrc.includes('reviewerDisplayName'),
    'CurrentTaskStrip.tsx must compute reviewerDisplayName',
  );
  assert.ok(
    !currentTaskStripSrc.includes('if (!raw || isVaultArmored(raw)) return \'\';'),
    'CurrentTaskStrip.tsx must not suppress criteria for armored tasks',
  );

  // chainTaskInference.ts support for reviewer agent_id
  const chainInferenceFile = path.join(REPO_ROOT, 'src/ui/components/chat/chainTaskInference.ts');
  const chainInferenceSrc = fs.readFileSync(chainInferenceFile, 'utf8');
  assert.ok(
    chainInferenceSrc.includes('agentId') || chainInferenceSrc.includes('agent_id'),
    'chainTaskInference.ts must check agent_id for task reviewer',
  );

  // AgentActivityBubbles decrypts embedded tokens
  const bubblesFile = path.join(REPO_ROOT, 'src/ui/components/chat/AgentActivityBubbles.tsx');
  const bubblesSrc = fs.readFileSync(bubblesFile, 'utf8');
  assert.ok(
    bubblesSrc.includes('decryptEmbeddedVaultTokens') || bubblesSrc.includes('containsVaultArmored'),
    'AgentActivityBubbles.tsx must handle embedded vault tokens',
  );

  // ConversationsHomePage consumes decrypted records
  const homePageFile = path.join(REPO_ROOT, 'src/ui/components/chat/ConversationsHomePage.tsx');
  const homePageSrc = fs.readFileSync(homePageFile, 'utf8');
  assert.ok(
    homePageSrc.includes('decryptConversationList'),
    'ConversationsHomePage.tsx must consume decrypted records via decryptConversationList',
  );
});
