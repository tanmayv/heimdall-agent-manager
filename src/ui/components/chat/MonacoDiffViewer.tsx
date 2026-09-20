import { useMemo } from 'react';
import { DiffEditor, type DiffEditorProps } from '@monaco-editor/react';
import type { VcsDiffHunk, VcsFileStatus } from '../../api/endpoints/projectVcs';
import { useTheme } from '../../store/themeSlice';
import { languageForFile } from '../../utils/codeHighlight';

export interface MonacoDiffViewerProps {
  hunks?: VcsDiffHunk[];
  original?: string;
  modified?: string;
  status?: VcsFileStatus;
  filePath: string;
  className?: string;
  sideBySide?: boolean;
  height?: number | string;
}

function getLanguageForMonaco(filePath: string): string {
  const lang = languageForFile(filePath);
  const map: Record<string, string> = {
    bash: 'shell',
    zsh: 'shell',
    sh: 'shell',
    fish: 'shell',
    docker: 'dockerfile',
    yml: 'yaml',
    js: 'javascript',
    ts: 'typescript',
    tsx: 'typescript',
    jsx: 'javascript',
  };
  return map[lang] || lang || 'plaintext';
}

export default function MonacoDiffViewer({
  hunks,
  original: originalProp,
  modified: modifiedProp,
  status,
  filePath,
  className = '',
  sideBySide = false,
  height,
}: MonacoDiffViewerProps) {
  const { theme } = useTheme();
  const monacoTheme = theme?.appearance === 'light' ? 'light' : 'vs-dark';

  const { original, modified, lineCount } = useMemo(() => {
    let orig = originalProp;
    let mod = modifiedProp;

    if (orig === undefined || mod === undefined) {
      const origLines: string[] = [];
      const modLines: string[] = [];

      for (const hunk of hunks || []) {
        for (const line of hunk.lines || []) {
          if (line.op === ' ' || line.op === '-') {
            origLines.push(line.text);
          }
          if (line.op === ' ' || line.op === '+') {
            modLines.push(line.text);
          }
        }
      }

      if (orig === undefined) orig = origLines.join('\n');
      if (mod === undefined) mod = modLines.join('\n');
    }

    // Handle added files (empty original) and deleted files (empty modified)
    if (status === 'added' || status === 'untracked') {
      orig = '';
    } else if (status === 'deleted') {
      mod = '';
    }

    const origCount = orig ? orig.split('\n').length : 0;
    const modCount = mod ? mod.split('\n').length : 0;

    return {
      original: orig,
      modified: mod,
      lineCount: Math.max(origCount, modCount, 1),
    };
  }, [hunks, originalProp, modifiedProp, status]);

  const language = useMemo(() => getLanguageForMonaco(filePath), [filePath]);

  const editorHeight = height ?? Math.min(Math.max(lineCount * 20 + 20, 160), 500);

  const options: DiffEditorProps['options'] = {
    readOnly: true,
    renderSideBySide: sideBySide ?? false,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    lineNumbers: 'on',
    wordWrap: 'off',
    automaticLayout: true,
  };

  return (
    <div
      data-debug-id="monaco-diff-viewer"
      className={`relative w-full overflow-hidden bg-canvas ${className}`}
    >
      <DiffEditor
        original={original}
        modified={modified}
        language={language}
        theme={monacoTheme}
        options={options}
        height={editorHeight}
        loading={<div className="p-3 text-center text-xs text-muted">Loading diff editor…</div>}
      />
    </div>
  );
}
