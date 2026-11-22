import { useEffect, useState } from 'react';
import { useSelector } from 'react-redux';
import { Icon } from '@ui';
import { useArtifactContentState, type ArtifactContentState } from '../api/endpoints/artifacts';
import { audioMimeForArtifact, type AudioArtifactMeta } from '../utils/audioArtifact';
import { AudioPlayer } from './chat/AudioPlayer';
import { VaultText } from './vault/VaultText';

type Session = { daemonUrl?: string; clientToken?: string };

/**
 * The session for content fetches. Transcripts pass an empty session and rely on cookie
 * auth (as the image previews do); `useArtifactContentState` spells that `v1` (ambient).
 */
export function artifactContentSession(sessionProp: Session | undefined, storeSession: Session | undefined): { daemonUrl: string; clientToken: string } {
  const session = sessionProp || storeSession || {};
  const token = String(session.clientToken || '').trim();
  if (!token || token === 'v1') return { daemonUrl: '', clientToken: 'v1' };
  return { daemonUrl: String(session.daemonUrl || ''), clientToken: token };
}

/**
 * A blob: URL of the (decrypted) content typed as audio. Decrypted vault payloads come back
 * as `application/octet-stream`; giving the blob its real media type lets <audio> pick a
 * decoder instead of sniffing. Revoked when the content or type changes and on unmount.
 */
export function useAudioBlobUrl(blob: Blob | null, mime: string): string {
  const [url, setUrl] = useState('');
  useEffect(() => {
    if (!blob) { setUrl(''); return; }
    const typed = mime && blob.type !== mime ? new Blob([blob], { type: mime }) : blob;
    const next = URL.createObjectURL(typed);
    setUrl(next);
    return () => URL.revokeObjectURL(next);
  }, [blob, mime]);
  return url;
}

/** Status line for content that is not playable (yet): loading, locked, failed. */
export function audioContentStatus(state: Pick<ArtifactContentState, 'loading' | 'error' | 'locked' | 'lockReason' | 'blob'>): string {
  if (state.locked) {
    return state.lockReason === 'other_vault'
      ? 'Encrypted by a previous vault. This audio cannot be opened.'
      : 'Encrypted audio. Unlock the vault to play it.';
  }
  if (state.error) return 'Audio unavailable.';
  if (state.loading || !state.blob) return 'Loading audio…';
  return '';
}

/** REQ-VOICE-3: an audio attachment in a transcript — name, inline player, link to the artifact. */
export function ArtifactAudioPreview({ artifactId, meta, session, debugId, href, label }: {
  artifactId: string;
  meta: AudioArtifactMeta | null;
  session?: Session;
  debugId: string;
  href: string;
  label: string;
}) {
  const storeSession = useSelector((state: any) => state.chat?.session) as Session | undefined;
  const { daemonUrl, clientToken } = artifactContentSession(session, storeSession);
  const content = useArtifactContentState({ daemonUrl, clientToken, artifactId });
  const url = useAudioBlobUrl(content.locked ? null : content.blob, audioMimeForArtifact(meta));
  const status = url ? '' : audioContentStatus(content);
  return (
    <div data-debug-id={`${debugId}-audio-card`}
      className="flex w-[min(360px,100%)] min-w-0 flex-col gap-1.5 rounded-xl border border-subtle bg-surface px-2.5 py-2">
      <AudioPlayer src={url} debugId={`${debugId}-audio-player`} label="Voice message" />
      <div className="flex min-w-0 items-center gap-2 text-caption text-muted">
        <Icon name="mic" size={12} className="shrink-0" />
        <span className="min-w-0 flex-1 truncate"><VaultText value={label} fallback={artifactId} /></span>
        {status ? <span data-debug-id={`${debugId}-audio-status`} className={content.error ? 'shrink-0 text-danger' : 'shrink-0 text-faint'}>{status}</span> : null}
        <a data-debug-id={`${debugId}-link`} href={href} className="shrink-0 text-faint hover:text-accent">Open</a>
      </div>
    </div>
  );
}
