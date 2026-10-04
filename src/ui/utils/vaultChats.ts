// Zero-Knowledge Vault Transformers for Chat Messages and Conversations
// REQ-VAULT-CHAT-1

import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  getActiveVaultKey,
} from './vaultContent.ts';

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
 * Encrypt chat message body if vault is unlocked using rawKeyHex or active CryptoKey.
 */
export async function encryptChatFields<T extends ChatMessagePayload>(
  payload: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !payload.body) return { ...payload };
  const res = { ...payload };
  if (!isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, activeKey);
  }
  return res;
}

/**
 * Encrypt conversation fields (title) if vault is unlocked using rawKeyHex or active CryptoKey.
 */
export async function encryptConversationFields<T extends ConversationPayload>(
  payload: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, activeKey);
  }
  return res;
}

/**
 * Decrypt chat message body using rawKeyHex or active CryptoKey.
 * Supports both fully armored strings and strings with embedded vault:v1: tokens.
 * Gracefully preserves unarmored plaintext or returns original text if locked/failed.
 */
export async function decryptChatMessage<T extends ChatMessagePayload>(
  message: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !message.body || (!isVaultArmored(message.body) && !containsVaultArmored(message.body))) {
    return message;
  }
  try {
    const decryptedBody = isVaultArmored(message.body)
      ? await decryptVaultText(message.body, activeKey)
      : await decryptEmbeddedVaultTokens(message.body, activeKey);
    return {
      ...message,
      body: decryptedBody,
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
  rawKeyHex?: string | CryptoKey | null,
): Promise<T[]> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !Array.isArray(messages)) return messages;
  return Promise.all(messages.map((m) => decryptChatMessage(m, activeKey)));
}

/**
 * Decrypt conversation fields (title, last_message_preview, lastMessagePreview, bodyPreview, lastMessage) using rawKeyHex or active CryptoKey.
 * Handles both fully armored strings and embedded ciphertext tokens (e.g. sender-prefixed previews).
 */
export async function decryptConversationRecord<T extends ConversationPayload>(
  conv: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return conv;
  let title = conv.title;
  let lastMessagePreview = conv.last_message_preview ?? conv.lastMessagePreview;
  let bodyPreview = conv.bodyPreview ?? (conv as any).body_preview;
  let lastMessage = conv.lastMessage;

  if (title && (isVaultArmored(title) || containsVaultArmored(title))) {
    try {
      title = isVaultArmored(title)
        ? await decryptVaultText(title, activeKey)
        : await decryptEmbeddedVaultTokens(title, activeKey);
    } catch {}
  }
  if (lastMessagePreview && (isVaultArmored(lastMessagePreview) || containsVaultArmored(lastMessagePreview))) {
    try {
      lastMessagePreview = isVaultArmored(lastMessagePreview)
        ? await decryptVaultText(lastMessagePreview, activeKey)
        : await decryptEmbeddedVaultTokens(lastMessagePreview, activeKey);
    } catch {}
  }
  if (bodyPreview && (isVaultArmored(bodyPreview) || containsVaultArmored(bodyPreview))) {
    try {
      bodyPreview = isVaultArmored(bodyPreview)
        ? await decryptVaultText(bodyPreview, activeKey)
        : await decryptEmbeddedVaultTokens(bodyPreview, activeKey);
    } catch {}
  }
  if (lastMessage && typeof lastMessage === 'object') {
    const lBody = lastMessage.body || lastMessage.bodyPreview;
    if (lBody && (isVaultArmored(lBody) || containsVaultArmored(lBody))) {
      try {
        const decryptedBody = isVaultArmored(lBody)
          ? await decryptVaultText(lBody, activeKey)
          : await decryptEmbeddedVaultTokens(lBody, activeKey);
        lastMessage = {
          ...lastMessage,
          ...(lastMessage.body !== undefined ? { body: decryptedBody } : {}),
          ...(lastMessage.bodyPreview !== undefined ? { bodyPreview: decryptedBody } : {}),
        };
      } catch {}
    }
  }

  return {
    ...conv,
    title,
    ...(lastMessagePreview !== undefined
      ? { last_message_preview: lastMessagePreview, lastMessagePreview }
      : {}),
    ...(bodyPreview !== undefined
      ? { bodyPreview, ...((conv as any).body_preview !== undefined ? { body_preview: bodyPreview } : {}) }
      : {}),
    ...(lastMessage !== undefined ? { lastMessage } : {}),
  };
}

/**
 * Decrypt an array of conversation records.
 */
export async function decryptConversationList<T extends ConversationPayload>(
  conversations: T[],
  rawKeyHex?: string | CryptoKey | null,
): Promise<T[]> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || !Array.isArray(conversations)) return conversations;
  return Promise.all(conversations.map((c) => decryptConversationRecord(c, activeKey)));
}
