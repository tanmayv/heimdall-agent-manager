import React from 'react';
import { MessageItem, MessageItemProps } from './MessageItem';
import { ChatActionCard } from './ChatActionCard';

export type ChatMessageItemProps = MessageItemProps;

export const ChatMessageItem: React.FC<ChatMessageItemProps> = (props) => {
  return <MessageItem {...props} />;
};

export { ChatActionCard };
export default ChatMessageItem;
