import { useState } from 'react';
import { useSelector } from 'react-redux';
import ArtifactViewer from './ArtifactViewer';
import MarkdownBody from './MarkdownBody';

type MarkdownProps = {
  source: string;
  className?: string;
  compact?: boolean;
  'data-debug-id'?: string;
};

export { renderMarkdown } from './MarkdownBody';

export default function Markdown({ source, className, compact, 'data-debug-id': dataDebugId }: MarkdownProps) {
  const session = useSelector((state: any) => state.chat?.session || {});
  const [activeArtifactId, setActiveArtifactId] = useState('');

  return (
    <>
      <MarkdownBody
        source={source}
        className={className}
        compact={compact}
        data-debug-id={dataDebugId}
        onArtifactClick={setActiveArtifactId}
      />
      {activeArtifactId && session?.daemonUrl && session?.clientToken ? (
        <ArtifactViewer artifactId={activeArtifactId} daemonUrl={session.daemonUrl} clientToken={session.clientToken} onClose={() => setActiveArtifactId('')} />
      ) : null}
    </>
  );
}
