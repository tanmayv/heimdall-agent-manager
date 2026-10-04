// Zero-Knowledge Vault Transformers for Tasks and Task Comments
// REQ-VAULT-TASKS-1

import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  getActiveVaultKey,
} from './vaultContent.ts';

export interface TaskPayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

export interface TaskCommentPayload {
  body: string;
  [key: string]: any;
}

/**
 * Encrypt task fields (title, description) if vault is unlocked using rawKeyHex or active CryptoKey.
 */
export async function encryptTaskFields<T extends TaskPayload>(
  payload: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, activeKey);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, activeKey);
  }
  return res;
}

/**
 * Encrypt task comment body if vault is unlocked using rawKeyHex or active CryptoKey.
 */
export async function encryptTaskCommentFields<T extends TaskCommentPayload>(
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
 * Decrypt task fields (title, description, last_comment_preview) using rawKeyHex or active CryptoKey.
 */
export async function decryptTaskRecord<T extends TaskPayload>(
  task: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey) return task;
  let title = task.title;
  let description = task.description;

  if (title) {
    if (isVaultArmored(title)) {
      try {
        title = await decryptVaultText(title, activeKey);
      } catch {}
    } else if (containsVaultArmored(title)) {
      try {
        title = await decryptEmbeddedVaultTokens(title, activeKey);
      } catch {}
    }
  }
  if (description) {
    if (isVaultArmored(description)) {
      try {
        description = await decryptVaultText(description, activeKey);
      } catch {}
    } else if (containsVaultArmored(description)) {
      try {
        description = await decryptEmbeddedVaultTokens(description, activeKey);
      } catch {}
    }
  }

  // Also decrypt comment summary if present
  let commentSummary = (task as any).comment_summary || (task as any).commentSummary;
  if (commentSummary && typeof commentSummary === 'object') {
    const preview = commentSummary.last_comment_preview || commentSummary.lastCommentPreview;
    if (preview) {
      if (isVaultArmored(preview)) {
        try {
          const decryptedPreview = await decryptVaultText(preview, activeKey);
          commentSummary = {
            ...commentSummary,
            last_comment_preview: decryptedPreview,
            lastCommentPreview: decryptedPreview,
          };
        } catch {}
      } else if (containsVaultArmored(preview)) {
        try {
          const decryptedPreview = await decryptEmbeddedVaultTokens(preview, activeKey);
          commentSummary = {
            ...commentSummary,
            last_comment_preview: decryptedPreview,
            lastCommentPreview: decryptedPreview,
          };
        } catch {}
      }
    }
  }

  return {
    ...task,
    title,
    description,
    ...(commentSummary ? { comment_summary: commentSummary, commentSummary } : {}),
  };
}

/**
 * Decrypt task comment record body using rawKeyHex or active CryptoKey.
 */
export async function decryptTaskCommentRecord<T extends TaskCommentPayload>(
  comment: T,
  rawKeyHex?: string | CryptoKey | null,
): Promise<T> {
  const activeKey = rawKeyHex || getActiveVaultKey();
  if (!activeKey || (!isVaultArmored(comment.body) && !containsVaultArmored(comment.body))) return comment;
  try {
    const decrypted = isVaultArmored(comment.body)
      ? await decryptVaultText(comment.body, activeKey)
      : await decryptEmbeddedVaultTokens(comment.body, activeKey);
    return {
      ...comment,
      body: decrypted,
    };
  } catch {
    return comment;
  }
}
