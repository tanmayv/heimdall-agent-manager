// Zero-Knowledge Vault Transformers for Chat Messages and Conversations
// REQ-VAULT-CHAT-1

import { isVaultArmored, encryptVaultText, decryptVaultText } from './vaultContent.ts';

export interface ChatMessagePayload {
  body?: string;
  [key: string]: any;
}

export interface ConversationPayload {
  title?: string;
  last_message_preview?: string;
  lastMessagePreview?: string;
  bodyPreview?: string;
  [key: string]: any;
}

/**
 * Encrypt chat message body if vault is unlocked using rawKeyHex.
 */
export async function encryptChatFields<T extends ChatMessagePayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex || !payload.body) return { ...payload };
  const res = { ...payload };
  if (!isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, rawKeyHex);
  }
  return res;
}

/**
 * Encrypt conversation fields (title) if vault is unlocked using rawKeyHex.
 */
export async function encryptConversationFields<T extends ConversationPayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, rawKeyHex);
  }
  return res;
}

/**
 * Decrypt chat message body using rawKeyHex.
 * Gracefully preserves unarmored plaintext or returns original text if locked/failed.
 */
export async function decryptChatMessage<T extends ChatMessagePayload>(
  message: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex || !message.body || !isVaultArmored(message.body)) return message;
  try {
    return {
      ...message,
      body: await decryptVaultText(message.body, rawKeyHex),
    };
  } catch {
    return message;
  }
}

/**
 * Decrypt an array of chat messages.
 */
export async function decryptChatMessages<T extends ChatMessagePayload>(
  messages: T[],
  rawKeyHex?: string | null,
): Promise<T[]> {
  if (!rawKeyHex || !Array.isArray(messages)) return messages;
  return Promise.all(messages.map((m) => decryptChatMessage(m, rawKeyHex)));
}

/**
 * Decrypt conversation fields (title, last_message_preview, lastMessagePreview, bodyPreview) using rawKeyHex.
 */
export async function decryptConversationRecord<T extends ConversationPayload>(
  conv: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return conv;
  let title = conv.title;
  let lastMessagePreview = conv.last_message_preview ?? conv.lastMessagePreview;
  let bodyPreview = conv.bodyPreview;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, rawKeyHex);
    } catch {}
  }
  if (lastMessagePreview && isVaultArmored(lastMessagePreview)) {
    try {
      lastMessagePreview = await decryptVaultText(lastMessagePreview, rawKeyHex);
    } catch {}
  }
  if (bodyPreview && isVaultArmored(bodyPreview)) {
    try {
      bodyPreview = await decryptVaultText(bodyPreview, rawKeyHex);
    } catch {}
  }

  return {
    ...conv,
    title,
    ...(lastMessagePreview !== undefined
      ? { last_message_preview: lastMessagePreview, lastMessagePreview }
      : {}),
    ...(bodyPreview !== undefined ? { bodyPreview } : {}),
  };
}

/**
 * Decrypt an array of conversation records.
 */
export async function decryptConversationList<T extends ConversationPayload>(
  conversations: T[],
  rawKeyHex?: string | null,
): Promise<T[]> {
  if (!rawKeyHex || !Array.isArray(conversations)) return conversations;
  return Promise.all(conversations.map((c) => decryptConversationRecord(c, rawKeyHex)));
}
