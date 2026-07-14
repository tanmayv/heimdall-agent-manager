import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { Vim } from '@vimee/shiki-editor';
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
            className="flex h-full w-full max-w-[38rem] flex-col border-l border-white/10 bg-[#0d0f14] shadow-2xl lg:max-w-[46rem]"
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
                <Vim
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
