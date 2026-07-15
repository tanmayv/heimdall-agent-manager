import { useState } from 'react';

type ChatHoverCopyButtonProps = {
  debugId: string;
  text: string;
  className?: string;
};

async function copyText(text: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const area = document.createElement('textarea');
  area.value = text;
  area.setAttribute('readonly', 'true');
  area.style.position = 'fixed';
  area.style.opacity = '0';
  document.body.appendChild(area);
  area.select();
  try {
    if (!document.execCommand('copy')) throw new Error('Copy command failed');
  } finally {
    document.body.removeChild(area);
  }
}

export default function ChatHoverCopyButton({ debugId, text, className = '' }: ChatHoverCopyButtonProps) {
  const [state, setState] = useState<'idle' | 'copied' | 'error'>('idle');
  const title = state === 'copied' ? 'Copied' : state === 'error' ? 'Copy failed' : 'Copy message';
  return (
    <button
      type="button"
      data-debug-id={debugId}
      aria-label={title}
      title={title}
      onClick={async () => {
        try {
          await copyText(text || '');
          setState('copied');
        } catch {
          setState('error');
        } finally {
          window.setTimeout(() => setState('idle'), 1400);
        }
      }}
      className={`opacity-0 transition-opacity hover:text-zinc-100 group-hover:opacity-100 focus:opacity-100 focus-visible:opacity-100 ${className}`}
    >
      {state === 'copied' ? '✓' : state === 'error' ? '!' : '⧉'}
    </button>
  );
}
