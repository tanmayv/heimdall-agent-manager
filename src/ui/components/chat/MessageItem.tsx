import React, { useState, useEffect } from 'react';
import { useSelector } from 'react-redux';
import { VaultText } from '../vault/VaultText';
import { isVaultArmored, decryptVaultText } from '../../utils/vaultContent';
import { selectIsVaultUnlocked, selectRawVaultKeyHex } from '../../store/vaultSlice';
import Markdown from '../Markdown';

export interface MessageItemProps {
  message: {
    messageId?: string;
    id?: string;
    body: string;
    author?: string;
    isUser?: boolean;
    createdUnixMs?: number;
    timestamp?: string;
    [key: string]: any;
  };
  className?: string;
}

export const MessageItem: React.FC<MessageItemProps> = ({ message, className = '' }) => {
  const messageId = String(message.messageId || message.id || '');
  const body = message.body || '';
  const isArmored = isVaultArmored(body);
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const rawKey = useSelector(selectRawVaultKeyHex);
  const [decryptedBody, setDecryptedBody] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    if (!isArmored) {
      setDecryptedBody(body);
      return;
    }
    if (!isUnlocked || !rawKey) {
      setDecryptedBody(null);
      return;
    }
    decryptVaultText(body, rawKey)
      .then((txt) => {
        if (active) setDecryptedBody(txt);
      })
      .catch(() => {
        if (active) setDecryptedBody(body);
      });
    return () => {
      active = false;
    };
  }, [body, isArmored, isUnlocked, rawKey]);

  return (
    <div
      data-debug-id={`message-item-${messageId}`}
      className={`message-item flex flex-col gap-1 py-1 ${className}`}
    >
      <div data-debug-id={`message-body-${messageId}`} className="text-sm">
        {isArmored && !isUnlocked ? (
          <VaultText value={body} as="div" />
        ) : (
          <Markdown source={decryptedBody ?? body} compact copyAll={false} />
        )}
      </div>
    </div>
  );
};

export default MessageItem;
