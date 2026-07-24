import { useMemo, useRef, useState } from 'react';
import ArtifactUploadButton from '../ArtifactUpload';
import RuntimeRestartControls from '../RuntimeRestartControls';
import { useIsMobile, useKeyboardInset, TOUCH_TARGET_CLASS } from '../shell/responsive';
import type { ChatComposerMention, ChatComposerMentionSuggestion, ChatComposerProps, ChatComposerSubmitPayload, ChatComposerUploadResult } from './types';

const MENTION_CATEGORIES: ChatComposerMention['type'][] = ['agent', 'task', 'task-chain', 'memory', 'project', 'artifact'];

type AttachmentState = {
  localId: string;
  file: File;
  name: string;
  kind: string;
  artifactId: string;
  link: string;
  progress: number;
  status: 'uploading' | 'uploaded' | 'error';
  error: string;
};

function noticeToneClasses(tone: 'error' | 'info' | 'neutral' = 'neutral') {
  if (tone === 'error') return 'border-red-400/30 bg-red-500/10 text-red-100';
  if (tone === 'info') return 'border-sky-400/30 bg-sky-400/10 text-sky-100';
  return 'border-white/10 bg-white/[0.04] text-zinc-300';
}

function attachmentKind(file: File): string {
  const type = String(file.type || '').toLowerCase();
  const name = String(file.name || '').toLowerCase();
  if (type.includes('png') || name.endsWith('.png')) return 'png';
  if (type.includes('jpeg') || name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'jpeg';
  if (type.includes('markdown') || name.endsWith('.md')) return 'markdown';
  if (type.includes('csv') || name.endsWith('.csv')) return 'csv';
  if (type.includes('html') || name.endsWith('.html') || name.endsWith('.htm')) return 'html';
  return 'file';
}

function artifactIdFromUpload(result: ChatComposerUploadResult): { artifactId: string; link: string } {
  if (!result) return { artifactId: '', link: '' };
  if (typeof result === 'string') {
    const link = result;
    return { artifactId: link.startsWith('artifact://') ? link.slice('artifact://'.length) : link, link };
  }
  const link = String(result.link || (result.artifactId ? `artifact://${result.artifactId}` : result.artifact_id ? `artifact://${result.artifact_id}` : ''));
  return { artifactId: String(result.artifactId || result.artifact_id || (link.startsWith('artifact://') ? link.slice('artifact://'.length) : '')), link };
}

function parseMentions(body: string): ChatComposerMention[] {
  const out: ChatComposerMention[] = [];
  const seen = new Set<string>();
  const re = /@((?:task-chain)|agent|task|memory|project|artifact):([A-Za-z0-9_.:-]+)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(body))) {
    const type = match[1] as ChatComposerMention['type'];
    const id = match[2];
    const key = `${type}:${id}`;
    if (!seen.has(key)) { seen.add(key); out.push({ type, id }); }
  }
  return out;
}

function activeMentionToken(body: string): { raw: string; category: ChatComposerMention['type'] | ''; query: string } | null {
  const tail = body.slice(Math.max(0, body.lastIndexOf(' ') + 1));
  if (!tail.startsWith('@')) return null;
  const withoutAt = tail.slice(1);
  const colon = withoutAt.indexOf(':');
  if (colon < 0) return { raw: tail, category: '', query: withoutAt };
  const category = withoutAt.slice(0, colon) as ChatComposerMention['type'];
  if (!MENTION_CATEGORIES.includes(category)) return null;
  return { raw: tail, category, query: withoutAt.slice(colon + 1) };
}

function mentionSuggestionsFor(body: string): ChatComposerMentionSuggestion[] {
  const active = activeMentionToken(body);
  if (!active) return [];
  if (!active.category) {
    const q = active.query.toLowerCase();
    return MENTION_CATEGORIES.filter((category) => category.startsWith(q)).map((category) => ({ type: category, id: '', label: `@${category}:`, metadata: 'mention category' }));
  }
  if (!active.query) return [{ type: active.category, id: '<id>', label: `@${active.category}:<id>`, metadata: 'type an id or choose a search result' }];
  return [{ type: active.category, id: active.query, label: `@${active.category}:${active.query}`, metadata: 'canonical mention text' }];
}

function replaceActiveMention(body: string, suggestion: ChatComposerMentionSuggestion): string {
  const active = activeMentionToken(body);
  const insert = suggestion.id ? `@${suggestion.type}:${suggestion.id}` : `@${suggestion.type}:`;
  if (!active) return `${body}${insert}`;
  const start = body.length - active.raw.length;
  return `${body.slice(0, start)}${insert} `;
}

export default function ChatComposer({
  shellDebugId,
  inputDebugId,
  sendButtonDebugId,
  sendAriaLabel,
  value,
  onValueChange,
  onSubmit,
  onPaste,
  onKeyDown,
  inputRef,
  placeholder,
  rows = 3,
  autoFocus = false,
  sendTitle = 'Send',
  sendDisabled = false,
  sendLabel = '→',
  sendError,
  sendErrorDebugId,
  uploadErrorDebugId,
  upload,
  runtimeControls,
  notices = [],
  leftAdornment,
  footer,
  keyboardHint = '⌘↵ to send',
  shellClassName = 'rounded-[15px] border border-white/10 bg-[#141414] p-0 focus-within:border-white/35',
  textareaClassName = 'w-full resize-none bg-transparent px-4 py-3 text-sm text-zinc-100 outline-none placeholder:text-zinc-500',
  controlsClassName = 'flex flex-wrap items-center justify-between gap-3 px-3 py-2',
  footerClassName = 'flex items-center justify-between border-t border-white/5 px-3 py-2 text-[11.5px] text-zinc-500',
  mobileBottomPinned = false,
}: ChatComposerProps) {
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const [attachments, setAttachments] = useState<AttachmentState[]>([]);
  const [dragActive, setDragActive] = useState(false);
  const [remoteMentionSuggestions, setRemoteMentionSuggestions] = useState<ChatComposerMentionSuggestion[]>([]);
  const localMentionSuggestions = useMemo(() => mentionSuggestionsFor(value), [value]);
  const parsedMentions = useMemo(() => parseMentions(value), [value]);
  const mentionSuggestions = remoteMentionSuggestions.length > 0 ? remoteMentionSuggestions : localMentionSuggestions;
  const hasUploadingAttachments = attachments.some((item) => item.status === 'uploading') || Boolean(upload?.uploading);
  const effectiveSendDisabled = sendDisabled || hasUploadingAttachments;
  // UI-13: keyboard/safe-area-aware on mobile only. `mobileBottomPinned` opts a
  // call site into bottom-pinning (conversation + task-comment composers). Hooks
  // are always called; effects no-op on desktop.
  const isMobile = useIsMobile();
  const keyboardInset = useKeyboardInset();
  const bottomPinnedActive = mobileBottomPinned && isMobile;

  async function refreshMentionSearch(nextValue: string) {
    const active = activeMentionToken(nextValue);
    if (!active?.category || !upload?.searchMentions) { setRemoteMentionSuggestions([]); return; }
    try {
      const rows = await upload.searchMentions(active.category, active.query);
      setRemoteMentionSuggestions(rows.slice(0, 8));
    } catch (_err) {
      setRemoteMentionSuggestions([]);
    }
  }

  async function uploadOne(file: File, existingLocalId = '') {
    if (!upload?.uploadFile || upload.disabled) return;
    const localId = existingLocalId || `att_${Date.now()}_${Math.random().toString(16).slice(2)}`;
    setAttachments((current) => {
      const next = current.filter((item) => item.localId !== localId);
      next.push({ localId, file, name: file.name || 'attachment', kind: attachmentKind(file), artifactId: '', link: '', progress: 10, status: 'uploading', error: '' });
      return next;
    });
    try {
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, progress: 40 } : item));
      const result = await upload.uploadFile(file);
      const parsed = artifactIdFromUpload(result);
      if (!parsed.artifactId) throw new Error('Upload completed without an artifact id.');
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, artifactId: parsed.artifactId, link: parsed.link, progress: 100, status: 'uploaded', error: '' } : item));
      upload.onUploaded?.(parsed.link || `artifact://${parsed.artifactId}`);
    } catch (err: any) {
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, progress: 100, status: 'error', error: String(err?.message || err || 'Upload failed') } : item));
    }
  }

  function uploadFiles(files: File[]) {
    if (!upload?.uploadFile) return;
    for (const file of files) void uploadOne(file);
  }

  function clipboardFiles(event: any): File[] {
    const files = Array.from(event?.clipboardData?.files || []) as File[];
    if (files.length > 0) return files;
    return (Array.from(event?.clipboardData?.items || []) as any[]).map((item) => item?.getAsFile?.()).filter(Boolean) as File[];
  }

  async function submitWithPayload() {
    const payload: ChatComposerSubmitPayload = {
      body: value,
      artifactIds: attachments.filter((item) => item.status === 'uploaded' && item.artifactId).map((item) => item.artifactId),
      mentions: upload?.sendStructuredMentions ? parsedMentions : undefined,
    };
    await onSubmit(payload);
    setAttachments([]);
  }

  return (
    <div
      data-debug-id={shellDebugId}
      data-upload-before-send="true"
      data-mobile-bottom-pinned={bottomPinnedActive ? 'true' : 'false'}
      className={`${shellClassName} ${dragActive ? 'ring-2 ring-sky-400/50' : ''} ${bottomPinnedActive ? 'ui-safe-bottom sticky bottom-0 z-20 bg-[#141414] md:static md:z-auto' : ''}`}
      style={bottomPinnedActive && keyboardInset ? { paddingBottom: keyboardInset } : undefined}
      onDragOver={(event) => { if (!upload?.uploadFile) return; event.preventDefault(); setDragActive(true); }}
      onDragLeave={() => setDragActive(false)}
      onDrop={(event) => { if (!upload?.uploadFile) return; event.preventDefault(); setDragActive(false); uploadFiles(Array.from(event.dataTransfer?.files || []) as File[]); }}
    >
      <textarea
        data-debug-id={inputDebugId}
        ref={inputRef}
        value={value}
        onChange={(event) => { onValueChange(event.target.value); void refreshMentionSearch(event.target.value); }}
        onPaste={(event) => {
          const files = clipboardFiles(event);
          if (files.length > 0 && upload?.uploadFile) { event.preventDefault(); uploadFiles(files); return; }
          onPaste?.(event);
        }}
        onKeyDown={(event) => {
          onKeyDown?.(event);
          if (event.defaultPrevented) return;
          if (event.key !== 'Enter' || event.shiftKey || !(event.metaKey || event.ctrlKey)) return;
          event.preventDefault();
          if (!effectiveSendDisabled) void submitWithPayload();
        }}
        placeholder={placeholder}
        autoFocus={autoFocus}
        rows={rows}
        className={textareaClassName}
      />
      {mentionSuggestions.length > 0 ? (
        <div data-debug-id={`${shellDebugId}-mention-autocomplete`} className="mx-3 mb-2 rounded-2xl border border-sky-400/20 bg-sky-400/10 p-2 text-xs text-sky-50">
          {mentionSuggestions.map((suggestion) => (
            <button key={`${suggestion.type}:${suggestion.id}:${suggestion.label}`} type="button" data-debug-id={`${shellDebugId}-mention-option-${suggestion.type}`} onClick={() => { onValueChange(replaceActiveMention(value, suggestion)); setRemoteMentionSuggestions([]); }} className="mr-2 mt-1 rounded-full border border-sky-200/20 bg-black/20 px-2 py-1 text-left hover:bg-sky-200/10">
              <span className="font-semibold">{suggestion.label}</span>{suggestion.metadata ? <span className="ml-1 text-sky-100/60">{suggestion.metadata}</span> : null}
            </button>
          ))}
        </div>
      ) : null}
      {parsedMentions.length > 0 ? (
        <div data-debug-id={`${shellDebugId}-mention-chips`} className="mx-3 mb-2 flex flex-wrap gap-1 text-[11px] text-violet-100">
          {parsedMentions.map((mention) => <span key={`${mention.type}:${mention.id}`} className="rounded-full border border-violet-300/20 bg-violet-400/10 px-2 py-1">@{mention.type}:{mention.id}</span>)}
        </div>
      ) : null}
      {attachments.length > 0 ? (
        <div data-debug-id={`${shellDebugId}-attachment-tray`} className="mx-3 mb-2 space-y-2 rounded-2xl border border-white/10 bg-white/[0.03] p-2 text-xs text-zinc-200">
          {attachments.map((attachment) => (
            <div key={attachment.localId} data-debug-id={`${shellDebugId}-attachment-chip`} className="rounded-xl border border-white/10 bg-black/20 p-2">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate"><strong>{attachment.name}</strong> · {attachment.kind}{attachment.artifactId ? ` · ${attachment.artifactId}` : ''}</span>
                <span className={attachment.status === 'error' ? 'text-red-300' : attachment.status === 'uploaded' ? 'text-emerald-300' : 'text-sky-300'}>{attachment.status}</span>
              </div>
              <div data-debug-id={`${shellDebugId}-attachment-progress`} className="mt-2 h-1.5 rounded-full bg-white/10"><div className="h-1.5 rounded-full bg-sky-300" style={{ width: `${attachment.progress}%` }} /></div>
              {attachment.error ? <div data-debug-id={`${shellDebugId}-attachment-error`} className="mt-2 text-red-300">{attachment.error}</div> : null}
              <div className="mt-2 flex gap-2">
                {attachment.status === 'error' ? <button type="button" data-debug-id={`${shellDebugId}-attachment-retry`} onClick={() => void uploadOne(attachment.file, attachment.localId)} className="rounded-full border border-white/10 px-2 py-1 text-zinc-200 hover:bg-white/10">Retry</button> : null}
                <button type="button" data-debug-id={`${shellDebugId}-attachment-remove`} onClick={() => setAttachments((current) => current.filter((item) => item.localId !== attachment.localId))} className="rounded-full border border-white/10 px-2 py-1 text-zinc-400 hover:bg-white/10">Remove</button>
              </div>
            </div>
          ))}
        </div>
      ) : null}
      {sendError && sendErrorDebugId ? <div data-debug-id={sendErrorDebugId} className="mx-3 mb-2 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{sendError}</div> : null}
      {upload?.error && uploadErrorDebugId ? <div data-debug-id={uploadErrorDebugId} className="mx-3 mb-2 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{upload.error}</div> : null}
      {notices.map((notice) => <div key={notice.debugId} data-debug-id={notice.debugId} className={`mx-3 mb-2 rounded-xl border px-3 py-2 text-xs ${noticeToneClasses(notice.tone)}`}>{notice.message}</div>)}
      <div className={controlsClassName}>
        <div className="flex flex-wrap items-center gap-2">
          {upload?.uploadFile ? (
            <>
              <input ref={fileInputRef} type="file" multiple data-debug-id={`${upload.debugIdPrefix}-input`} className="hidden" onChange={(event) => { uploadFiles(Array.from(event.target.files || []) as File[]); event.target.value = ''; }} />
              <button type="button" data-debug-id={`${upload.debugIdPrefix}-btn`} disabled={upload.disabled || hasUploadingAttachments} onClick={() => { upload.clearError?.(); fileInputRef.current?.click(); }} className={upload.buttonClassName || 'framer-pill bg-white/10 text-zinc-100 hover:bg-white/15 disabled:cursor-not-allowed disabled:opacity-40'}>{hasUploadingAttachments ? 'Uploading…' : (upload.label || 'Attach')}</button>
            </>
          ) : upload ? (
            <ArtifactUploadButton
              onUploaded={(link) => upload.onUploaded?.(link)}
              context={upload.context}
              disabled={upload.disabled}
              debugIdPrefix={upload.debugIdPrefix}
              label={upload.label}
              buttonClassName={upload.buttonClassName}
            />
          ) : null}
          {runtimeControls ? (
            <RuntimeRestartControls
              debugPrefix={runtimeControls.debugPrefix}
              providers={runtimeControls.providers}
              projects={runtimeControls.projects}
              provider={runtimeControls.provider}
              modelTier={runtimeControls.modelTier}
              projectId={runtimeControls.projectId}
              disabled={runtimeControls.disabled}
              restarting={runtimeControls.restarting}
              showProject={runtimeControls.showProject}
              onRestart={runtimeControls.onRestart}
            />
          ) : null}
          {leftAdornment}
        </div>
        <div className="flex items-center gap-2">
          <span className="hidden text-[11px] text-zinc-600 sm:inline">{hasUploadingAttachments ? 'Uploads finish before send' : keyboardHint}</span>
          <button type="button" data-debug-id={sendButtonDebugId} aria-label={sendAriaLabel} title={sendTitle} onClick={() => { if (!effectiveSendDisabled) void submitWithPayload(); }} disabled={effectiveSendDisabled} className={`inline-flex items-center justify-center gap-1 rounded-full border border-white/10 px-3 text-sm text-zinc-500 hover:bg-[#1c1c1c] hover:text-zinc-100 disabled:cursor-not-allowed disabled:opacity-50 ${isMobile ? `min-h-11 px-4 ${TOUCH_TARGET_CLASS}` : 'h-8'}`}>{sendLabel}</button>
        </div>
      </div>
      {footer ? <div className={footerClassName}>{footer}</div> : null}
    </div>
  );
}
