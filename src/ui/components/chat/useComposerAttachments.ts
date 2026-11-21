import { useState, type ClipboardEvent } from 'react';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { MAX_UPLOAD_BYTES, UPLOAD_TOO_LARGE_ERROR } from '../ArtifactUpload';
import { artifactKindForFile, artifactLinkFromResponse, artifactMimeForFile, artifactUploadName, clipboardFilesFromEvent } from '../../utils/artifactUpload';

export type PendingAttachment = {
  localId: string;
  id: string;
  name: string;
  file: File;
  status: 'uploading' | 'uploaded' | 'error';
  error: string;
};

type Metadata = Pick<Parameters<ReturnType<typeof useCreateArtifactMutation>[0]>[0],
  'originKind' | 'originRef' | 'projectId' | 'agentId' | 'agentInstanceId' | 'chainId'>;

export function useComposerAttachments({ metadata, namePrefix, canUpload = () => true, onUploadStart, errorText }: {
  metadata: Metadata;
  namePrefix: string;
  canUpload?: () => boolean;
  onUploadStart?: () => void;
  errorText: (error: unknown) => string;
}) {
  const [createArtifact] = useCreateArtifactMutation();
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);

  async function uploadAttachment(file: File, existingLocalId = '') {
    if (!canUpload()) return;
    const localId =
      existingLocalId || `att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, namePrefix);
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    onUploadStart?.();
    setAttachments((current) => {
      const without = current.filter((item) => item.localId !== localId);
      return [
        ...without,
        {
          localId,
          id: '',
          name,
          file,
          status: tooLarge ? 'error' : 'uploading',
          error: tooLarge
            ? UPLOAD_TOO_LARGE_ERROR
            : '',
        },
      ];
    });
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        ...metadata,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = link.replace(/^artifact:\/\//i, '');
      if (!id) throw new Error('Upload failed: Hub did not return an artifact id.');
      setAttachments((current) =>
        current.map((item) =>
          item.localId === localId ? { ...item, id, status: 'uploaded', error: '' } : item,
        ),
      );
    } catch (err: any) {
      setAttachments((current) =>
        current.map((item) =>
          item.localId === localId
            ? { ...item, status: 'error', error: errorText(err) }
            : item,
        ),
      );
    }
  }

  function handlePaste(event: ClipboardEvent<HTMLTextAreaElement>) {
    if (!canUpload()) return;
    const files = clipboardFilesFromEvent(event);
    if (!files.length) return;
    event.preventDefault();
    files.forEach(file => void uploadAttachment(file));
  }

  return { attachments, setAttachments, uploadAttachment, handlePaste };
}
