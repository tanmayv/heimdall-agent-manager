import ArtifactUploadButton from '../ArtifactUpload';
import RuntimeRestartControls from '../RuntimeRestartControls';
import type { ChatComposerProps } from './types';

function noticeToneClasses(tone: 'error' | 'info' | 'neutral' = 'neutral') {
  if (tone === 'error') return 'border-red-400/30 bg-red-500/10 text-red-100';
  if (tone === 'info') return 'border-sky-400/30 bg-sky-400/10 text-sky-100';
  return 'border-white/10 bg-white/[0.04] text-zinc-300';
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
}: ChatComposerProps) {
  return (
    <div data-debug-id={shellDebugId} className={shellClassName}>
      <textarea
        data-debug-id={inputDebugId}
        ref={inputRef}
        value={value}
        onChange={(event) => onValueChange(event.target.value)}
        onPaste={onPaste}
        onKeyDown={(event) => {
          onKeyDown?.(event);
          if (event.defaultPrevented) return;
          if (event.key !== 'Enter' || event.shiftKey || !(event.metaKey || event.ctrlKey)) return;
          event.preventDefault();
          void onSubmit();
        }}
        placeholder={placeholder}
        autoFocus={autoFocus}
        rows={rows}
        className={textareaClassName}
      />
      {sendError && sendErrorDebugId ? <div data-debug-id={sendErrorDebugId} className="mx-3 mb-2 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{sendError}</div> : null}
      {upload?.error && uploadErrorDebugId ? <div data-debug-id={uploadErrorDebugId} className="mx-3 mb-2 rounded-xl border border-red-400/30 bg-red-500/10 px-3 py-2 text-xs text-red-100">{upload.error}</div> : null}
      {notices.map((notice) => <div key={notice.debugId} data-debug-id={notice.debugId} className={`mx-3 mb-2 rounded-xl border px-3 py-2 text-xs ${noticeToneClasses(notice.tone)}`}>{notice.message}</div>)}
      <div className={controlsClassName}>
        <div className="flex flex-wrap items-center gap-2">
          {upload ? (
            <ArtifactUploadButton
              onUploaded={upload.onUploaded}
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
          <span className="hidden text-[11px] text-zinc-600 sm:inline">{keyboardHint}</span>
          <button data-debug-id={sendButtonDebugId} aria-label={sendAriaLabel} title={sendTitle} onClick={() => { void onSubmit(); }} disabled={sendDisabled} className="inline-flex h-8 items-center justify-center rounded-full border border-white/10 px-3 text-sm text-zinc-500 hover:bg-[#1c1c1c] hover:text-zinc-100 disabled:cursor-not-allowed disabled:opacity-50">{sendLabel}</button>
        </div>
      </div>
      {footer ? <div className={footerClassName}>{footer}</div> : null}
    </div>
  );
}
