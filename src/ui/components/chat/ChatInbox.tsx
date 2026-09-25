import React from 'react';
import { VaultText } from '../vault/VaultText';

export interface ChatInboxConversation {
  conversationId: string;
  title?: string;
  lastMessagePreview?: string;
  last_message_preview?: string;
  unreadCount?: number;
  updatedAt?: string;
  [key: string]: any;
}

export interface ChatInboxProps {
  conversations: ChatInboxConversation[];
  activeConversationId?: string;
  onSelectConversation?: (conversationId: string) => void;
  className?: string;
}

export const ChatInbox: React.FC<ChatInboxProps> = ({
  conversations,
  activeConversationId,
  onSelectConversation,
  className = '',
}) => {
  return (
    <div data-debug-id="chat-inbox-list" className={`chat-inbox flex flex-col divide-y divide-subtle ${className}`}>
      {conversations.map((conv) => {
        const preview = conv.last_message_preview || conv.lastMessagePreview || '';
        const isActive = conv.conversationId === activeConversationId;
        return (
          <div
            key={conv.conversationId}
            data-debug-id={`chat-inbox-item-${conv.conversationId}`}
            onClick={() => onSelectConversation?.(conv.conversationId)}
            className={`cursor-pointer p-3 hover:bg-neutral-soft transition-colors ${
              isActive ? 'bg-surface-raised' : ''
            }`}
          >
            <div
              data-debug-id={`chat-inbox-title-${conv.conversationId}`}
              className="font-semibold text-primary text-sm truncate"
            >
              <VaultText value={conv.title || 'Untitled conversation'} as="span" />
            </div>
            {preview ? (
              <div
                data-debug-id={`chat-inbox-preview-${conv.conversationId}`}
                className="text-xs text-muted truncate mt-0.5"
              >
                <VaultText value={preview} as="span" />
              </div>
            ) : null}
          </div>
        );
      })}
    </div>
  );
};

export default ChatInbox;
