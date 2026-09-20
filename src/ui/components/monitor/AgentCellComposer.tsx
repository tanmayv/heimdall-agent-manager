// Slim per-cell message composer for the Agent Monitor grid (REQ-AM-8).
//
// A minimal counterpart to the full ConversationThreadPage composer: a 2-row textarea
// (Cmd/Ctrl+Enter to send), a send button, and an attach/paste path that uploads files
// as artifacts and delivers their ids alongside the message. It reuses the shared
// artifactUpload helpers and the same createArtifact -> send-message flow the main
// composer uses, kept intentionally lean so each monitor cell stays compact.

import { useCallback, useRef, useState, type ChangeEvent, type ClipboardEvent, type KeyboardEvent } from 'react';
import Icon from '../Icon';
import { useSendConversationMessageMutation } from '../../api/endpoints/chats';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import {
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';

function errText(e: any, fallback: string): string {
  return String(e?.data?.message || e?.error || e?.message || '') || fallback;
}

export interface AgentCellComposerProps {
  agentInstanceId: string;
  conversationId: string;
}

export function AgentCellComposer({ agentInstanceId, conversationId }: AgentCellComposerProps) {
  const [draft, setDraft] = useState('');
  const [pendingIds, setPendingIds] = useState<string[]>([]);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [sendMessage, sendState] = useSendConversationMessageMutation();
  const [createArtifact] = useCreateArtifactMutation();

  const uploadFile = useCallback(async (file: File) => {
    if (!conversationId) { setError('No conversation for this agent.'); return; }
    if (file.size > MAX_UPLOAD_BYTES) {
      setError(`File is too large (max ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB).`);
      return;
    }
    setUploading(true);
    setError('');
    try {
      const res = await createArtifact({
        file,
        name: artifactUploadName(file, 'monitor-attachment'),
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'conversation_chat',
        originRef: conversationId,
        agentInstanceId,
      }).unwrap();
      const id = artifactLinkFromResponse(res).replace(/^artifact:\/\//i, '');
      if (!id) throw new Error('Upload failed: no artifact id returned.');
      setPendingIds((prev) => [...prev, id]);
    } catch (e: any) {
      setError(errText(e, 'Upload failed'));
    } finally {
      setUploading(false);
    }
  }, [conversationId, agentInstanceId, createArtifact]);

  const onPaste = useCallback((e: ClipboardEvent<HTMLTextAreaElement>) => {
    const files = clipboardFilesFromEvent(e);
    if (files.length === 0) return;
    e.preventDefault();
    files.forEach((f) => void uploadFile(f));
  }, [uploadFile]);

  const onFileInput = useCallback((e: ChangeEvent<HTMLInputElement>) => {
    const files = Array.from(e.target.files || []);
    e.target.value = '';
    files.forEach((f) => void uploadFile(f));
  }, [uploadFile]);

  const send = useCallback(async () => {
    const body = draft.trim();
    if ((!body && pendingIds.length === 0) || !conversationId || sendState.isLoading) return;
    try {
      await sendMessage({
        conversationId,
        body: body || 'Uploaded file',
        artifactIds: pendingIds,
      }).unwrap();
      setDraft('');
      setPendingIds([]);
      setError('');
    } catch (e: any) {
      setError(errText(e, 'Could not send message'));
    }
  }, [draft, pendingIds, conversationId, sendState.isLoading, sendMessage]);

  const onKeyDown = useCallback((e: KeyboardEvent<HTMLTextAreaElement>) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      void send();
    }
  }, [send]);

  const sendDisabled = (!draft.trim() && pendingIds.length === 0) || !conversationId || sendState.isLoading;

  return (
    <div data-debug-id={`monitor-composer-${agentInstanceId}`} className="flex shrink-0 flex-col gap-1 border-t border-subtle bg-surface-raised p-1.5">
      {error ? <p className="truncate text-[10px] text-danger" title={error}>{error}</p> : null}
      {pendingIds.length > 0 ? (
        <p className="text-[10px] text-muted">{pendingIds.length} attachment{pendingIds.length === 1 ? '' : 's'} ready</p>
      ) : null}
      <div className="flex items-end gap-1">
        <textarea
          rows={2}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={onKeyDown}
          onPaste={onPaste}
          placeholder="Message… (⌘/Ctrl+Enter)"
          data-debug-id={`monitor-composer-input-${agentInstanceId}`}
          className="min-w-0 flex-1 resize-none rounded border border-subtle bg-canvas px-2 py-1 text-[11px] font-mono text-primary placeholder:text-muted focus:outline-none focus:ring-1 focus:ring-accent"
        />
        <input ref={fileInputRef} type="file" multiple className="hidden" onChange={onFileInput} data-debug-id={`monitor-composer-file-${agentInstanceId}`} />
        <button
          type="button"
          title="Attach file"
          aria-label="Attach file"
          disabled={uploading || !conversationId}
          onClick={() => fileInputRef.current?.click()}
          className="grid h-8 w-8 shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-40"
        >
          <Icon name="file" size={14} />
        </button>
        <button
          type="button"
          title="Send (⌘/Ctrl+Enter)"
          aria-label="Send message"
          disabled={sendDisabled}
          onClick={() => void send()}
          data-debug-id={`monitor-composer-send-${agentInstanceId}`}
          className="grid h-8 w-8 shrink-0 place-items-center rounded bg-accent/15 text-accent hover:bg-accent/25 disabled:opacity-40"
        >
          <Icon name="arrow-up" size={14} />
        </button>
      </div>
    </div>
  );
}

export default AgentCellComposer;
