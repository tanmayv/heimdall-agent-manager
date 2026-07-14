import React, { createContext, useContext, useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { computeSelectionInfo, Line, StatusLine, useShikiTokens } from '@vimee/shiki-editor';
import { useVim } from '@vimee/react';
import { createHighlighter, type HighlighterGeneric } from 'shiki';

export interface VimSessionConfig {
  title: string;
  initialValue: string;
  language?: 'markdown' | 'typescript' | 'json' | 'yaml' | 'javascript';
  onApply: (updatedText: string) => void;
}

interface VimSidebarContextType {
  openVim: (config: VimSessionConfig) => void;
  closeVim: () => void;
  isOpen: boolean;
}

const VimSidebarContext = createContext<VimSidebarContextType | null>(null);

type ArrowDirection = 'left' | 'right' | 'up' | 'down';

type HeimdallVimProps = {
  content: string;
  highlighter: HighlighterGeneric<any, any>;
  lang: string;
  theme: string;
  onChange?: (content: string) => void;
  onSave?: (content: string) => void;
  onModeChange?: (mode: any) => void;
  showLineNumbers?: boolean;
  autoFocus?: boolean;
  className?: string;
};

function moveCursorForArrow(ctx: any, buffer: any, direction: ArrowDirection) {
  const lineCount = Math.max(1, buffer.getLineCount?.() || 1);
  const currentLine = Math.min(Math.max(0, ctx.cursor.line), lineCount - 1);
  const currentCol = Math.max(0, ctx.cursor.col);
  if (direction === 'left') {
    if (currentCol > 0) return { line: currentLine, col: currentCol - 1 };
    if (currentLine > 0) return { line: currentLine - 1, col: buffer.getLineLength(currentLine - 1) };
    return { line: currentLine, col: 0 };
  }
  if (direction === 'right') {
    const lineLength = buffer.getLineLength(currentLine);
    if (currentCol < lineLength) return { line: currentLine, col: currentCol + 1 };
    if (currentLine < lineCount - 1) return { line: currentLine + 1, col: 0 };
    return { line: currentLine, col: lineLength };
  }
  const nextLine = direction === 'up' ? Math.max(0, currentLine - 1) : Math.min(lineCount - 1, currentLine + 1);
  return { line: nextLine, col: Math.min(currentCol, buffer.getLineLength(nextLine)) };
}

const INSERT_ARROW_KEYBINDS = [
  { mode: 'insert' as const, keys: '<C-h>', execute: (ctx: any, buffer: any) => [{ type: 'cursor-move' as const, position: moveCursorForArrow(ctx, buffer, 'left') }] },
  { mode: 'insert' as const, keys: '<C-l>', execute: (ctx: any, buffer: any) => [{ type: 'cursor-move' as const, position: moveCursorForArrow(ctx, buffer, 'right') }] },
  { mode: 'insert' as const, keys: '<C-k>', execute: (ctx: any, buffer: any) => [{ type: 'cursor-move' as const, position: moveCursorForArrow(ctx, buffer, 'up') }] },
  { mode: 'insert' as const, keys: '<C-j>', execute: (ctx: any, buffer: any) => [{ type: 'cursor-move' as const, position: moveCursorForArrow(ctx, buffer, 'down') }] },
];

function visualColumn(line: string, col: number, tabSize: number) {
  let visual = 0;
  for (let i = 0; i < col && i < line.length; i += 1) {
    visual += line[i] === '\t' ? tabSize - (visual % tabSize) : 1;
  }
  return visual;
}

function wrappedRowsForLine(line: string, wrapColumns: number, tabSize: number) {
  const cols = Math.max(0, visualColumn(line, line.length, tabSize));
  return Math.max(1, Math.floor(Math.max(0, cols - 1) / Math.max(1, wrapColumns)) + 1);
}

function measureEditorWrapColumns(area: HTMLElement, gutterWidth: number, showLineNumbers: boolean) {
  const style = window.getComputedStyle(area);
  const probe = document.createElement('span');
  probe.textContent = '0'.repeat(64);
  probe.style.position = 'absolute';
  probe.style.visibility = 'hidden';
  probe.style.whiteSpace = 'pre';
  probe.style.fontFamily = style.fontFamily;
  probe.style.fontSize = style.fontSize;
  probe.style.fontWeight = style.fontWeight;
  area.appendChild(probe);
  const charWidth = Math.max(1, probe.getBoundingClientRect().width / 64);
  probe.remove();
  const padLeft = Number.parseFloat(style.paddingLeft || '0') || 0;
  const padRight = Number.parseFloat(style.paddingRight || '0') || 0;
  const gutterPx = showLineNumbers ? (gutterWidth + 1) * charWidth : 0;
  const available = Math.max(charWidth * 12, area.clientWidth - padLeft - padRight - gutterPx);
  return Math.max(12, Math.floor(available / charWidth));
}

function HeimdallVim({ content: initialContent, highlighter, lang, theme, onChange, onSave, onModeChange, showLineNumbers = true, autoFocus = false, className }: HeimdallVimProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const codeAreaRef = useRef<HTMLDivElement | null>(null);
  const [wrapColumns, setWrapColumns] = useState(80);
  const [lineHeight, setLineHeight] = useState(20);
  const [paddingTop, setPaddingTop] = useState(8);
  const [paddingLeft, setPaddingLeft] = useState(16);
  const tabSize = 4;

  useEffect(() => {
    if (autoFocus) containerRef.current?.focus();
  }, [autoFocus]);

  const engine = useVim({
    content: initialContent,
    onChange,
    onSave,
    onModeChange,
    keybinds: INSERT_ARROW_KEYBINDS,
  });

  const { tokenLines, bgColor, fgColor } = useShikiTokens(highlighter, engine.content, lang, theme);
  const effectiveShowLineNumbers = engine.options.number !== undefined ? engine.options.number : showLineNumbers;
  const totalLines = tokenLines.length;
  const gutterWidth = String(totalLines).length;
  const lines = useMemo(() => engine.content.split('\n'), [engine.content]);

  useEffect(() => {
    const area = codeAreaRef.current;
    if (!area) return undefined;
    const update = () => {
      const style = window.getComputedStyle(area);
      setWrapColumns(measureEditorWrapColumns(area, gutterWidth, effectiveShowLineNumbers));
      setLineHeight(Number.parseFloat(style.lineHeight || '20') || 20);
      setPaddingTop(Number.parseFloat(style.paddingTop || '8') || 8);
      setPaddingLeft(Number.parseFloat(style.paddingLeft || '16') || 16);
    };
    update();
    const observer = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(update) : null;
    observer?.observe(area);
    window.addEventListener('resize', update);
    return () => {
      observer?.disconnect();
      window.removeEventListener('resize', update);
    };
  }, [gutterWidth, effectiveShowLineNumbers]);

  const visualCol = useMemo(() => visualColumn(lines[engine.cursor.line] || '', engine.cursor.col, tabSize), [lines, engine.cursor.line, engine.cursor.col]);

  const cursorLayout = useMemo(() => {
    const safeWrap = Math.max(1, wrapColumns);
    let visualRow = 0;
    for (let i = 0; i < engine.cursor.line; i += 1) {
      visualRow += wrappedRowsForLine(lines[i] || '', safeWrap, tabSize);
    }
    visualRow += Math.floor(visualCol / safeWrap);
    const wrappedCol = visualCol % safeWrap;
    const gutterOffset = effectiveShowLineNumbers ? gutterWidth + 1 : 0;
    return {
      top: paddingTop + visualRow * lineHeight,
      leftCh: gutterOffset + wrappedCol,
    };
  }, [effectiveShowLineNumbers, engine.cursor.line, gutterWidth, lineHeight, lines, paddingTop, visualCol, wrapColumns]);

  const selectionInfo = useMemo(() => computeSelectionInfo(engine.mode, engine.visualAnchor, engine.cursor), [engine.mode, engine.visualAnchor, engine.cursor]);

  const searchMatchesByLine = useMemo(() => {
    if (!engine.commandLine || !(engine.commandLine.startsWith('/') || engine.commandLine.startsWith('?'))) return {} as Record<number, [number, number][]>;
    const pattern = engine.commandLine.slice(1);
    if (!pattern) return {} as Record<number, [number, number][]>;
    try {
      const regex = new RegExp(pattern, 'gi');
      return lines.reduce<Record<number, [number, number][]>>((acc, line, idx) => {
        const matches = [...line.matchAll(regex)];
        if (matches.length > 0) acc[idx] = matches.map((m) => [m.index || 0, (m.index || 0) + m[0].length]);
        return acc;
      }, {});
    } catch {
      return {} as Record<number, [number, number][]>;
    }
  }, [engine.commandLine, lines]);

  useEffect(() => {
    const area = codeAreaRef.current;
    if (!area) return;
    const cursorTop = cursorLayout.top;
    const cursorBottom = cursorTop + lineHeight;
    if (cursorTop < area.scrollTop) area.scrollTop = cursorTop;
    else if (cursorBottom > area.scrollTop + area.clientHeight) area.scrollTop = cursorBottom - area.clientHeight;
  }, [cursorLayout.top, lineHeight]);

  const handleKeyDown = useCallback((event: React.KeyboardEvent<HTMLDivElement>) => {
    const arrowRemap: Record<string, string> = { ArrowLeft: 'h', ArrowRight: 'l', ArrowUp: 'k', ArrowDown: 'j' };
    if (engine.mode === 'insert' && arrowRemap[event.key]) {
      event.preventDefault();
      event.stopPropagation();
      engine.handleKeyDown({ key: arrowRemap[event.key], ctrlKey: true, nativeEvent: { isComposing: false }, preventDefault() {} } as React.KeyboardEvent<HTMLDivElement>);
      return;
    }
    engine.handleKeyDown(event);
    if (event.ctrlKey && codeAreaRef.current) {
      const scrollKeys: Record<string, { direction: 'up' | 'down'; amount: number }> = { b: { direction: 'up', amount: 1 }, f: { direction: 'down', amount: 1 }, u: { direction: 'up', amount: 0.5 }, d: { direction: 'down', amount: 0.5 } };
      const scroll = scrollKeys[event.key];
      if (scroll) {
        const visibleLines = Math.floor(codeAreaRef.current.clientHeight / lineHeight);
        engine.handleScroll(scroll.direction, visibleLines, scroll.amount);
      }
    }
  }, [engine, lineHeight]);

  useEffect(() => {
    const area = codeAreaRef.current;
    if (!area) return undefined;
    const updateViewportInfo = () => {
      const topLine = Math.floor((area.scrollTop - paddingTop) / lineHeight);
      const visibleLines = Math.floor(area.clientHeight / lineHeight);
      engine.updateViewport(Math.max(0, topLine), visibleLines);
    };
    updateViewportInfo();
    area.addEventListener('scroll', updateViewportInfo);
    window.addEventListener('resize', updateViewportInfo);
    return () => {
      area.removeEventListener('scroll', updateViewportInfo);
      window.removeEventListener('resize', updateViewportInfo);
    };
  }, [engine, lineHeight, paddingTop]);

  return (
    <div ref={containerRef} className={`sv-container${className ? ` ${className}` : ''}`} style={{ backgroundColor: bgColor, color: fgColor, '--sv-tab-size': String(tabSize) } as React.CSSProperties} tabIndex={0} onKeyDown={handleKeyDown} role="textbox" aria-label="Code editor" aria-multiline="true">
      <div ref={codeAreaRef} className="sv-code-area">
        <div
          className={`sv-cursor ${engine.mode === 'insert' ? 'sv-cursor-line' : 'sv-cursor-block'}`}
          style={{ '--cursor-top': `${cursorLayout.top}px`, '--cursor-left': `calc(${paddingLeft}px + ${cursorLayout.leftCh}ch)` } as React.CSSProperties}
          aria-hidden="true"
        />
        {tokenLines.map((tokens, lineIndex) => (
          <Line
            key={lineIndex}
            lineIndex={lineIndex}
            tokens={tokens}
            showLineNumbers={effectiveShowLineNumbers}
            totalLines={totalLines}
            isSelected={selectionInfo.isLineSelected(lineIndex)}
            selectionStartCol={selectionInfo.getSelectionStartCol(lineIndex)}
            selectionEndCol={selectionInfo.getSelectionEndCol(lineIndex)}
            searchMatches={searchMatchesByLine[lineIndex]}
          />
        ))}
      </div>
      <StatusLine mode={engine.mode} cursor={engine.cursor} statusMessage={engine.statusMessage} statusError={engine.statusError} commandLine={engine.commandLine} totalLines={totalLines} />
    </div>
  );
}

export function useVimSidebar(): VimSidebarContextType {
  const context = useContext(VimSidebarContext);
  if (!context) {
    throw new Error('useVimSidebar must be used within a VimSidebarProvider');
  }
  return context;
}

export function VimSidebarProvider({ children }: { children: React.ReactNode }) {
  const [sessionConfig, setSessionConfig] = useState<VimSessionConfig | null>(null);
  const [isOpen, setIsOpen] = useState(false);
  const [highlighter, setHighlighter] = useState<HighlighterGeneric<any, any> | null>(null);
  const [highlighterError, setHighlighterError] = useState<string | null>(null);
  const [currentContent, setCurrentContent] = useState('');

  // Initialize Shiki highlighter
  useEffect(() => {
    let isMounted = true;
    createHighlighter({
      themes: ['github-dark'],
      langs: ['markdown', 'typescript', 'json', 'yaml', 'javascript'],
    })
      .then((hl) => {
        if (isMounted) setHighlighter(hl);
      })
      .catch((err) => {
        if (isMounted) {
          console.error('Failed to initialize Shiki highlighter:', err);
          setHighlighterError(err?.message || String(err));
        }
      });
    return () => {
      isMounted = false;
    };
  }, []);

  const openVim = useCallback((config: VimSessionConfig) => {
    setSessionConfig(config);
    setCurrentContent(config.initialValue || '');
    setIsOpen(true);
  }, []);

  const closeVim = useCallback(() => {
    setIsOpen(false);
    setSessionConfig(null);
  }, []);

  const handleApply = useCallback(() => {
    if (sessionConfig) {
      sessionConfig.onApply(currentContent);
    }
    closeVim();
  }, [sessionConfig, currentContent, closeVim]);

  return (
    <VimSidebarContext.Provider value={{ openVim, closeVim, isOpen }}>
      {children}
      {isOpen && sessionConfig && (
        <div className="fixed inset-0 z-50 flex justify-end bg-black/60 backdrop-blur-xs transition-opacity">
          <aside
            data-debug-id="vim-sidebar-panel"
            className="flex h-full w-full max-w-[45.6rem] flex-col border-l border-white/10 bg-[#0d0f14] shadow-2xl lg:max-w-[55.2rem]"
          >
            {/* Sidebar Header */}
            <div className="flex items-center justify-between border-b border-white/10 px-5 py-4">
              <div>
                <div className="flex items-center gap-2">
                  <span className="text-lg font-bold tracking-tight text-white">Vim Editor Mode</span>
                  <span className="rounded-md bg-emerald-500/15 px-2 py-0.5 font-mono text-xs font-semibold text-emerald-400">
                    VIMEE
                  </span>
                </div>
                <div className="mt-0.5 text-xs text-zinc-400">
                  Target field: <span className="font-semibold text-zinc-200">{sessionConfig.title}</span>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  data-debug-id="vim-sidebar-cancel-btn"
                  onClick={closeVim}
                  className="rounded-xl bg-white/5 px-3 py-1.5 text-xs font-medium text-zinc-400 transition hover:bg-white/10 hover:text-white"
                >
                  Cancel (:q!)
                </button>
                <button
                  type="button"
                  data-debug-id="vim-sidebar-apply-btn"
                  onClick={handleApply}
                  className="rounded-xl bg-emerald-500 px-3.5 py-1.5 text-xs font-semibold text-black transition hover:bg-emerald-400"
                >
                  Apply & Close (:wq)
                </button>
                <button
                  type="button"
                  data-debug-id="vim-sidebar-close-btn"
                  onClick={closeVim}
                  aria-label="Close Vim Editor"
                  className="ml-1 rounded-lg p-1 text-zinc-400 hover:bg-white/10 hover:text-white"
                >
                  <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
            </div>

            {/* Helper Bar */}
            <div className="flex items-center justify-between bg-black/40 px-5 py-2 text-xs text-zinc-400">
              <div className="flex items-center gap-3">
                <span><span>Normal mode:</span> <code className="rounded bg-white/10 px-1 py-0.5 font-mono text-[11px] text-emerald-300">i</code> (Insert)</span>
                <span><span>Command:</span> <code className="rounded bg-white/10 px-1 py-0.5 font-mono text-[11px] text-emerald-300">:wq</code> (Save)</span>
                <span><code className="rounded bg-white/10 px-1 py-0.5 font-mono text-[11px] text-emerald-300">ESC</code> (Normal)</span>
              </div>
              <div className="text-zinc-500 font-mono">
                Lang: {sessionConfig.language || 'markdown'}
              </div>
            </div>

            {/* Editor Surface */}
            <div className="vimee-editor-container flex-1 overflow-hidden bg-[#0a0c10]">
              {!highlighter ? (
                <div className="flex h-full flex-col items-center justify-center gap-3 text-sm text-zinc-400">
                  {highlighterError ? (
                    <div className="rounded-xl border border-red-500/20 bg-red-500/10 p-4 text-red-200">
                      Error loading syntax engine: {highlighterError}
                    </div>
                  ) : (
                    <>
                      <div className="h-6 w-6 animate-spin rounded-full border-2 border-emerald-400 border-t-transparent" />
                      <span>Initializing Shiki syntax engine & Vimee...</span>
                    </>
                  )}
                </div>
              ) : (
                <HeimdallVim
                  content={currentContent}
                  highlighter={highlighter}
                  lang={sessionConfig.language || 'markdown'}
                  theme="github-dark"
                  onChange={(newContent: string) => setCurrentContent(newContent)}
                  onSave={(savedContent: string) => {
                    setCurrentContent(savedContent);
                    sessionConfig.onApply(savedContent);
                    closeVim();
                  }}
                  showLineNumbers={true}
                  autoFocus={true}
                  className="h-full w-full"
                />
              )}
            </div>
          </aside>
        </div>
      )}
    </VimSidebarContext.Provider>
  );
}

export function VimEditButton({
  debugId,
  title,
  value,
  onApply,
  lang = 'markdown',
}: {
  debugId: string;
  title: string;
  value: string;
  onApply: (val: string) => void;
  lang?: 'markdown' | 'typescript' | 'json' | 'yaml' | 'javascript';
}) {
  const { openVim } = useVimSidebar();
  return (
    <button
      type="button"
      data-debug-id={debugId}
      onClick={(e) => {
        e.preventDefault();
        openVim({ title, initialValue: value, onApply, language: lang });
      }}
      aria-label={`Open ${title} in Vim Mode sidebar`}
      className="inline-flex h-8 w-8 items-center justify-center rounded-lg border border-emerald-500/30 bg-emerald-500/10 text-sm font-semibold text-emerald-300 transition hover:border-emerald-500 hover:bg-emerald-500/20"
      title="Open in Vim Mode sidebar (:wq to save)"
    >
      <span aria-hidden="true">⌘</span>
    </button>
  );
}
