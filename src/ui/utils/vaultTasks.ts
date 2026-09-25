// Zero-Knowledge Vault Transformers for Tasks and Task Comments
// REQ-VAULT-TASKS-1

import { isVaultArmored, encryptVaultText, decryptVaultText } from './vaultContent.ts';

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
 * Encrypt task fields (title, description) if vault is unlocked using rawKeyHex.
 */
export async function encryptTaskFields<T extends TaskPayload>(
  payload: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, rawKeyHex);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, rawKeyHex);
  }
  return res;
}

/**
 * Encrypt task comment body if vault is unlocked using rawKeyHex.
 */
export async function encryptTaskCommentFields<T extends TaskCommentPayload>(
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
 * Decrypt task fields (title, description, last_comment_preview) using rawKeyHex.
 */
export async function decryptTaskRecord<T extends TaskPayload>(
  task: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex) return task;
  let title = task.title;
  let description = task.description;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, rawKeyHex);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, rawKeyHex);
    } catch {}
  }

  // Also decrypt comment summary if present
  let commentSummary = (task as any).comment_summary || (task as any).commentSummary;
  if (commentSummary && typeof commentSummary === 'object') {
    const preview = commentSummary.last_comment_preview || commentSummary.lastCommentPreview;
    if (preview && isVaultArmored(preview)) {
      try {
        const decryptedPreview = await decryptVaultText(preview, rawKeyHex);
        commentSummary = {
          ...commentSummary,
          last_comment_preview: decryptedPreview,
          lastCommentPreview: decryptedPreview,
        };
      } catch {}
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
 * Decrypt task comment record body using rawKeyHex.
 */
export async function decryptTaskCommentRecord<T extends TaskCommentPayload>(
  comment: T,
  rawKeyHex?: string | null,
): Promise<T> {
  if (!rawKeyHex || !isVaultArmored(comment.body)) return comment;
  try {
    return {
      ...comment,
      body: await decryptVaultText(comment.body, rawKeyHex),
    };
  } catch {
    return comment;
  }
}
