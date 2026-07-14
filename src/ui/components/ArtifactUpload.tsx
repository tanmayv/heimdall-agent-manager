import { useCallback, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import * as daemonApi from '../api/daemonApi';

// MVP artifact upload support is limited to Markdown/text and PNG. Keep this in
// sync with the daemon allowlist and the fullscreen viewer preview branches.
const MARKDOWN_EXTENSIONS = ['.md', '.markdown'];
const PNG_EXTENSIONS = ['.png'];
export const ARTIFACT_UPLOAD_ACCEPT = '.md,.markdown,text/markdown,.png,image/png';
const MAX_UPLOAD_BYTES = 5 * 1024 * 1024; // Mirror daemon size guardrail for a friendlier client-side error.

type ArtifactKindMime = { kind: string; mime: string };

function classifyFile(file: File): ArtifactKindMime | null {
  const name = (file.name || '').toLowerCase();
  const type = (file.type || '').toLowerCase();
  const hasExt = (exts: string[]) => exts.some((ext) => name.endsWith(ext));
  if (hasExt(MARKDOWN_EXTENSIONS) || type === 'text/markdown' || (type === 'text/plain' && hasExt(MARKDOWN_EXTENSIONS))) {
    return { kind: 'markdown', mime: 'text/markdown' };
  }
  if (hasExt(PNG_EXTENSIONS) || type === 'image/png') {
    return { kind: 'png', mime: 'image/png' };
  }
  return null;
}

function readFileAsBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(new Error('Failed to read file.'));
    reader.onload = () => {
      const result = String(reader.result || '');
      const comma = result.indexOf(',');
      resolve(comma >= 0 ? result.slice(comma + 1) : result);
    };
    reader.readAsDataURL(file);
  });
}

export type ArtifactUploadContext = {
  projectId?: string;
  originRef?: string;
};

export type UseArtifactUploadResult = {
  uploading: boolean;
  error: string;
  clearError: () => void;
  uploadFile: (file: File | null | undefined) => Promise<string | null>;
};

// Reusable upload flow used by the direct/selected-agent composer and the chain
// coordinator composer. Returns the created `artifact://<id>` link on success or
// null on failure, setting a human-readable `error` for the caller to surface.
export function useArtifactUpload(context: ArtifactUploadContext = {}): UseArtifactUploadResult {
  const session = useSelector((state: any) => state.chat?.session || {});
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const clearError = useCallback(() => setError(''), []);

  const uploadFile = useCallback(async (file: File | null | undefined): Promise<string | null> => {
    if (!file) return null;
    setError('');
    const classified = classifyFile(file);
    if (!classified) {
      setError('Unsupported file. Upload a Markdown (.md) or PNG (.png) file.');
      return null;
    }
    if (file.size > MAX_UPLOAD_BYTES) {
      setError('File is too large. Maximum upload size is 5 MB.');
      return null;
    }
    if (!session?.daemonUrl || !session?.clientToken) {
      setError('Not connected. Reconnect before uploading an artifact.');
      return null;
    }
    setUploading(true);
    try {
      const contentBase64 = await readFileAsBase64(file);
      const res = await daemonApi.createArtifact({
        daemonUrl: session.daemonUrl,
        clientToken: session.clientToken,
        name: file.name || `artifact${classified.kind === 'png' ? '.png' : '.md'}`,
        kind: classified.kind,
        mime: classified.mime,
        projectId: context.projectId || '',
        originKind: 'chat',
        originRef: context.originRef || '',
        contentBase64,
      });
      const link = res?.link || (res?.artifact?.artifact_id ? `artifact://${res.artifact.artifact_id}` : '');
      if (!link) {
        setError('Upload failed: daemon did not return an artifact link.');
        return null;
      }
      return link;
    } catch (err: any) {
      setError(String(err?.message || err || 'Failed to upload artifact.'));
      return null;
    } finally {
      setUploading(false);
    }
  }, [session?.daemonUrl, session?.clientToken, context.projectId, context.originRef]);

  return { uploading, error, clearError, uploadFile };
}

export type ArtifactUploadButtonProps = {
  onUploaded: (link: string) => void;
  context?: ArtifactUploadContext;
  disabled?: boolean;
  debugIdPrefix?: string;
  className?: string;
  buttonClassName?: string;
  label?: string;
};

// Self-contained upload affordance: a visible button wired to a hidden native
// file input plus inline validation/error display. `debugIdPrefix` controls the
// data-debug-id namespace so each composer can expose stable, unique IDs.
export default function ArtifactUploadButton({
  onUploaded,
  context,
  disabled,
  debugIdPrefix = 'artifact-upload',
  className,
  buttonClassName,
  label = 'Attach artifact',
}: ArtifactUploadButtonProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const { uploading, error, clearError, uploadFile } = useArtifactUpload(context || {});

  const handleChange = useCallback(async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    // Reset the input so selecting the same file again re-triggers change.
    event.target.value = '';
    if (!file) return;
    const link = await uploadFile(file);
    if (link) onUploaded(link);
  }, [uploadFile, onUploaded]);

  return (
    <div className={className}>
      <input
        ref={inputRef}
        type="file"
        accept={ARTIFACT_UPLOAD_ACCEPT}
        data-debug-id={`${debugIdPrefix}-input`}
        className="hidden"
        onChange={handleChange}
      />
      <button
        type="button"
        data-debug-id={`${debugIdPrefix}-btn`}
        disabled={disabled || uploading}
        onClick={() => { clearError(); inputRef.current?.click(); }}
        title="Upload a Markdown or PNG artifact"
        className={buttonClassName || 'framer-pill bg-white/10 text-zinc-100 hover:bg-white/15 disabled:cursor-not-allowed disabled:opacity-40'}
      >
        {uploading ? 'Uploading…' : label}
      </button>
      {error && (
        <div data-debug-id={`${debugIdPrefix}-error`} className="mt-1 text-xs text-red-300">{error}</div>
      )}
    </div>
  );
}
