import type { ReactNode } from 'react';
import Markdown from '../Markdown';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import type { StreamRevealOptions } from './streamReveal';

export function PlainMessageBody({ body, artifactIds, messageId, debugPrefix, reveal, children, textContent }: {
  body: string; artifactIds?: string[]; messageId: string; debugPrefix: string;
  reveal?: StreamRevealOptions; children?: ReactNode; textContent?: ReactNode;
}) {
  return <div className="flex flex-col gap-1">
    {children}
    {textContent === undefined ? <Markdown source={body} compact copyAll={false} reveal={reveal} /> : textContent}
    {artifactIds && artifactIds.length > 0 && <div className="mt-2 flex max-w-full flex-wrap gap-2">
      {artifactIds.map(id => <ArtifactAttachmentPreview key={id} artifactId={id}
        session={{ daemonUrl: '', clientToken: '' }} debugId={`${debugPrefix}-artifact-${messageId}-${id}`} />)}
    </div>}
  </div>;
}
