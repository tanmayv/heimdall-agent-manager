import type { KeyboardEvent, ReactNode, RefObject } from 'react';

export type ChatMessage = {
  key: string;
  messageId: string;
  body: string;
  isUser: boolean;
  createdUnixMs: number;
  deliveredUnixMs: number;
  readUnixMs: number;
  deliveryFailedUnixMs: number;
  deliveryError: string;
  sending: boolean;
  authorLabel: string;
  artifactIds?: string[];
};

export type ChatTimestamp = { label: string; iso: string };
export type ChatDeliveryStatus = { glyph: string; label: string; tone: string };

export type ChatComposerNotice = {
  debugId: string;
  message: ReactNode;
  tone?: 'error' | 'info' | 'neutral';
};

export type ChatComposerMention = {
  type: 'agent' | 'task' | 'task-chain' | 'memory' | 'project' | 'artifact';
  id: string;
};

export type ChatComposerMentionSuggestion = ChatComposerMention & {
  label: string;
  metadata?: string;
};

export type ChatComposerSubmitPayload = {
  body: string;
  artifactIds: string[];
  mentions?: ChatComposerMention[];
};

export type ChatComposerUploadResult = string | { artifactId?: string; artifact_id?: string; link?: string; name?: string; kind?: string } | null | undefined;

export type ChatComposerUploadProps = {
  onUploaded?: (link: string) => void;
  uploadFile?: (file: File) => Promise<ChatComposerUploadResult>;
  searchMentions?: (category: ChatComposerMention['type'], query: string) => Promise<ChatComposerMentionSuggestion[]>;
  context?: { projectId?: string; originRef?: string; originKind?: string };
  disabled?: boolean;
  uploading?: boolean;
  debugIdPrefix: string;
  buttonClassName?: string;
  label?: string;
  error?: string;
  clearError?: () => void;
  sendStructuredMentions?: boolean;
};

export type ChatComposerRuntimeControlsProps = {
  debugPrefix: string;
  providers?: any[];
  projects?: any[];
  provider: string;
  modelTier: string;
  projectId: string;
  disabled?: boolean;
  restarting?: boolean;
  showProject?: boolean;
  onRestart: (next: { provider: string; modelTier: string; projectId: string }) => void | Promise<void>;
};

export type ChatComposerProps = {
  shellDebugId: string;
  inputDebugId: string;
  sendButtonDebugId: string;
  sendAriaLabel: string;
  value: string;
  onValueChange: (value: string) => void;
  onSubmit: (payload?: ChatComposerSubmitPayload) => void | Promise<void>;
  onPaste?: (event: any) => void | Promise<void>;
  onKeyDown?: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  inputRef?: RefObject<HTMLTextAreaElement | null>;
  placeholder: string;
  rows?: number;
  autoFocus?: boolean;
  sendTitle?: string;
  sendDisabled?: boolean;
  sendLabel?: ReactNode;
  sendError?: string;
  sendErrorDebugId?: string;
  uploadErrorDebugId?: string;
  upload?: ChatComposerUploadProps | null;
  runtimeControls?: ChatComposerRuntimeControlsProps | null;
  notices?: ChatComposerNotice[];
  leftAdornment?: ReactNode;
  footer?: ReactNode;
  keyboardHint?: ReactNode;
  shellClassName?: string;
  textareaClassName?: string;
  controlsClassName?: string;
  footerClassName?: string;
  // UI-13: when true, the composer is bottom-pinned on mobile and lifts above
  // the soft keyboard via safe-area + visualViewport insets. No effect on desktop.
  mobileBottomPinned?: boolean;
};
