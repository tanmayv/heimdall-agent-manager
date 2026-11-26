import { openArtifactPage } from '../utils/artifactPage';
import MarkdownBody, { type MarkdownTextSelection } from './MarkdownBody';
import type { StreamRevealOptions } from './chat/streamReveal';

type MarkdownProps = {
  source: string;
  className?: string;
  compact?: boolean;
  copyAll?: boolean;
  onTextSelectionChange?: (selection: MarkdownTextSelection | null) => void;
  /** Word-by-word reveal of a live reply (chat/streamReveal.ts). Omit to render instantly. */
  reveal?: StreamRevealOptions;
  'data-debug-id'?: string;
};

export { renderMarkdown } from './MarkdownBody';

export default function Markdown({ source, className, compact, copyAll = true, onTextSelectionChange, reveal, 'data-debug-id': dataDebugId }: MarkdownProps) {
  return (
    <MarkdownBody
      source={source}
      className={className}
      compact={compact}
      copyAll={copyAll}
      data-debug-id={dataDebugId}
      onArtifactClick={openArtifactPage}
      onTextSelectionChange={onTextSelectionChange}
      reveal={reveal}
    />
  );
}
