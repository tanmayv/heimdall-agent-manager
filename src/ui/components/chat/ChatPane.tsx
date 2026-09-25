import React from 'react';
import { VaultText } from '../vault/VaultText';
import { MessageItem, MessageItemProps } from './MessageItem';

export type ChatPaneMessage = MessageItemProps['message'];

export interface ChatPaneConversation {
  conversationId: string;
  title?: string;
  [key: string]: any;
}

export interface ChatPaneProps {
  conversation?: ChatPaneConversation | null;
  messages?: ChatPaneMessage[];
  className?: string;
}

export const ChatPane: React.FC<ChatPaneProps> = ({
  conversation,
  messages = [],
  className = '',
}) => {
  const convId = conversation?.conversationId || '';
  return (
    <div data-debug-id={`chat-pane-${convId}`} className={`chat-pane flex flex-col h-full ${className}`}>
      <header data-debug-id={`chat-pane-header-${convId}`} className="border-b border-subtle p-3">
        <h2 data-debug-id={`chat-pane-title-${convId}`} className="text-base font-semibold text-primary">
          <VaultText value={conversation?.title || 'Chat'} as="span" />
        </h2>
      </header>
      <div data-debug-id={`chat-pane-messages-${convId}`} className="flex-1 overflow-y-auto p-4 space-y-3">
        {messages.map((msg, idx) => (
          <MessageItem key={msg.messageId || msg.id || idx} message={msg} />
        ))}
      </div>
    </div>
  );
};

export default ChatPane;
