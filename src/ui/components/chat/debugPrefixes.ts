export const chainCoordinatorChatDebug = {
  messageList: 'chain-coordinator',
  workBanner: 'chain-coordinator',
  composer: 'chain-coordinator',
  upload: 'chain-coordinator-artifact-upload',
  runtime: 'chain-coordinator',
  sidebar: 'chain-task-surface',
} as const;

export const conversationChatDebug = {
  header: 'conversation-thread',
  messageList: 'conversation-thread',
  workBanner: 'conversation-composer',
  composer: 'conversation-composer',
  upload: 'conversation-attach',
  runtime: 'conversation',
  artifacts: 'conversation-thread',
} as const;

export const agentDetailChatDebug = {
  header: 'agent-detail-chat',
  messageList: 'agent-detail-chat',
  workBanner: 'agent-detail-chat',
  composer: 'agent-detail-chat',
  upload: 'agent-detail-chat-artifact-upload',
  runtime: 'agent-detail-chat',
  artifacts: 'agent-detail-chat',
  sidebar: 'agent-detail-chat-sidebar',
} as const;
