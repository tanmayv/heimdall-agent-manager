import React from 'react';
import { MessageItem, MessageItemProps } from './MessageItem';

export type ChatMessageItemProps = MessageItemProps;

export const ChatMessageItem: React.FC<ChatMessageItemProps> = (props) => {
  return <MessageItem {...props} />;
};

export default ChatMessageItem;
