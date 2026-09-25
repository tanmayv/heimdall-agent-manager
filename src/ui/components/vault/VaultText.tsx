// Zero-Knowledge VaultText Reusable Component & Decryption Hooks
// REQ-VAULT-ISSUES-UI-1
import React, { useState, useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
  openUnlockModal,
} from '../../store/vaultSlice';
import {
  isVaultArmored,
  decryptVaultText,
  decryptList,
} from '../../utils/vaultContent';

export interface VaultTextProps {
  value?: string | null;
  fallback?: string;
  as?: 'span' | 'p' | 'div';
  className?: string;
  onUnlockClick?: () => void;
  title?: string;
}

/**
 * Reusable VaultText component:
 * - If value is unencrypted / not armored, renders plaintext directly.
 * - If value is armored and vault is unlocked, decrypts and renders plaintext.
 * - If value is armored and vault is locked, renders an interactive placeholder
 *   with data-debug-id='vault-locked-placeholder' that triggers openUnlockModal on click.
 */
export function VaultText({
  value,
  fallback = '',
  as = 'span',
  className,
  onUnlockClick,
  title,
}: VaultTextProps) {
  const dispatch = useDispatch();
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const rawKey = useSelector(selectRawVaultKeyHex);

  const rawString = value ?? '';
  const isArmored = isVaultArmored(rawString);

  const [decryptedText, setDecryptedText] = useState<string | null>(null);
  const [isDecrypting, setIsDecrypting] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    if (!isArmored) {
      setDecryptedText(rawString);
      setIsDecrypting(false);
      return;
    }

    if (!isUnlocked || !rawKey) {
      setDecryptedText(null);
      setIsDecrypting(false);
      return;
    }

    setIsDecrypting(true);
    decryptVaultText(rawString, rawKey)
      .then((decrypted) => {
        if (mounted) {
          setDecryptedText(decrypted);
          setIsDecrypting(false);
        }
      })
      .catch((err) => {
        if (mounted) {
          console.error('Failed to decrypt vault armored text:', err);
          setDecryptedText(fallback || '[Decryption failed]');
          setIsDecrypting(false);
        }
      });

    return () => {
      mounted = false;
    };
  }, [rawString, isArmored, isUnlocked, rawKey, fallback]);

  const Tag = as;

  // 1. Not armored: render plaintext directly
  if (!isArmored) {
    return (
      <Tag className={className} title={title}>
        {rawString || fallback}
      </Tag>
    );
  }

  // 2. Armored and vault is locked: render interactive placeholder
  if (!isUnlocked || !rawKey) {
    return (
      <button
        type="button"
        data-debug-id="vault-locked-placeholder"
        onClick={(e) => {
          e.stopPropagation();
          if (onUnlockClick) {
            onUnlockClick();
          } else {
            dispatch(openUnlockModal());
          }
        }}
        title={title || 'Encrypted content — click to unlock vault'}
        aria-label="Encrypted content — click to unlock vault"
        className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded text-xs font-mono font-medium bg-neutral-soft hover:bg-neutral-raised text-accent border border-subtle cursor-pointer transition-colors select-none ${className || ''}`}
      >
        <span aria-hidden="true">🔒</span>
        <span>[🔒 Encrypted content - click to unlock]</span>
      </button>
    );
  }

  // 3. Armored and currently decrypting
  if (isDecrypting && decryptedText === null) {
    return (
      <Tag className={`${className || ''} opacity-60 italic`} title={title}>
        {fallback || 'Decrypting...'}
      </Tag>
    );
  }

  // 4. Armored and decrypted: render plaintext
  return (
    <Tag className={className} title={title}>
      {decryptedText !== null ? decryptedText : fallback}
    </Tag>
  );
}

/**
 * Hook to decrypt an individual string value reactively.
 */
export function useDecryptedText(value?: string | null): {
  text: string;
  isArmored: boolean;
  isLocked: boolean;
  isDecrypting: boolean;
} {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const rawKey = useSelector(selectRawVaultKeyHex);
  const raw = value ?? '';
  const isArmored = isVaultArmored(raw);

  const [text, setText] = useState<string>(raw);
  const [isDecrypting, setIsDecrypting] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    if (!isArmored) {
      setText(raw);
      setIsDecrypting(false);
      return;
    }
    if (!isUnlocked || !rawKey) {
      setText(raw);
      setIsDecrypting(false);
      return;
    }
    setIsDecrypting(true);
    decryptVaultText(raw, rawKey)
      .then((decrypted) => {
        if (mounted) {
          setText(decrypted);
          setIsDecrypting(false);
        }
      })
      .catch(() => {
        if (mounted) {
          setText(raw);
          setIsDecrypting(false);
        }
      });
    return () => {
      mounted = false;
    };
  }, [raw, isArmored, isUnlocked, rawKey]);

  return {
    text,
    isArmored,
    isLocked: isArmored && !isUnlocked,
    isDecrypting,
  };
}

/**
 * Hook to decrypt an array of issue objects reactively when vault is unlocked.
 */
export function useDecryptedIssues<T extends { title?: string; description?: string; description_preview?: string; descriptionPreview?: string }>(
  items: T[],
): T[] {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const rawKey = useSelector(selectRawVaultKeyHex);
  const [decryptedList, setDecryptedList] = useState<T[]>(items);

  useEffect(() => {
    let mounted = true;
    if (!isUnlocked || !rawKey || items.length === 0) {
      setDecryptedList(items);
      return;
    }

    const hasArmored = items.some(
      (item) =>
        isVaultArmored(item.title) ||
        isVaultArmored(item.description) ||
        isVaultArmored(item.description_preview) ||
        isVaultArmored(item.descriptionPreview),
    );

    if (!hasArmored) {
      setDecryptedList(items);
      return;
    }

    decryptList(
      items,
      ['title', 'description', 'description_preview', 'descriptionPreview'] as (keyof T)[],
      rawKey,
    )
      .then((res) => {
        if (mounted) setDecryptedList(res);
      })
      .catch((err) => {
        console.error('Failed to decrypt issues list:', err);
        if (mounted) setDecryptedList(items);
      });

    return () => {
      mounted = false;
    };
  }, [items, isUnlocked, rawKey]);

  return decryptedList;
}

export default VaultText;
