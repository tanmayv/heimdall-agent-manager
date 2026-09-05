// Shared, lazy Shiki highlighter for the file/code viewers.
//
// Uses Shiki's CORE API + the JavaScript regex engine (NOT the oniguruma WASM
// engine): the wasm path (`shiki` full bundle -> `shiki/wasm`) doesn't bundle
// cleanly under our Rollup/Vite config, and the JS engine is wasm-free and works
// in the browser. Themes/languages are loaded on demand via dynamic imports and
// cached, so the initial payload stays small and unknown languages degrade to
// plain text (caller renders a plain <pre>).

import type { HighlighterCore } from 'shiki/core';

const THEME = 'github-dark';

let highlighterPromise: Promise<HighlighterCore> | null = null;
const loadedLangs = new Set<string>();
const loadingLangs = new Map<string, Promise<boolean>>();

// Map a filename / extension to a Shiki language id. Returns '' when we have no
// good mapping (caller renders plain text).
export function languageForFile(pathOrName: string): string {
  const name = String(pathOrName || '').toLowerCase();
  const base = name.slice(name.lastIndexOf('/') + 1);
  const ext = base.includes('.') ? base.slice(base.lastIndexOf('.') + 1) : '';

  const byName: Record<string, string> = {
    dockerfile: 'docker',
    makefile: 'make',
  };
  if (byName[base]) return byName[base];

  const byExt: Record<string, string> = {
    ts: 'typescript', tsx: 'tsx', js: 'javascript', jsx: 'jsx', mjs: 'javascript', cjs: 'javascript',
    json: 'json', jsonc: 'jsonc',
    md: 'markdown', markdown: 'markdown',
    html: 'html', htm: 'html', xml: 'xml', svg: 'xml',
    css: 'css', scss: 'scss', sass: 'sass', less: 'less',
    py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', kt: 'kotlin',
    c: 'c', h: 'c', cpp: 'cpp', cc: 'cpp', cxx: 'cpp', hpp: 'cpp', hxx: 'cpp',
    cs: 'csharp', swift: 'swift', php: 'php', lua: 'lua', r: 'r',
    sh: 'bash', bash: 'bash', zsh: 'bash', fish: 'fish',
    yml: 'yaml', yaml: 'yaml', toml: 'toml', ini: 'ini', cfg: 'ini', conf: 'ini',
    sql: 'sql', graphql: 'graphql', gql: 'graphql', proto: 'proto',
    docker: 'docker', nix: 'nix', zig: 'zig',
    vue: 'vue', svelte: 'svelte', diff: 'diff', patch: 'diff',
    make: 'make', cmake: 'cmake', toml_: 'toml',
  };
  return byExt[ext] || '';
}

async function getHighlighter(): Promise<HighlighterCore> {
  if (!highlighterPromise) {
    highlighterPromise = (async () => {
      const [{ createHighlighterCore }, { createJavaScriptRegexEngine }, theme] = await Promise.all([
        import('shiki/core'),
        import('shiki/engine/javascript'),
        import('@shikijs/themes/github-dark'),
      ]);
      return createHighlighterCore({
        themes: [theme.default],
        langs: [],
        engine: createJavaScriptRegexEngine(),
      });
    })();
  }
  return highlighterPromise;
}

// Explicit lang -> dynamic-import loader map. Each is a STATIC import specifier so
// Vite/Rollup code-splits every grammar into its own chunk (loaded only when a
// file of that language is opened). Unlisted languages fall back to plain text.
const LANG_LOADERS: Record<string, () => Promise<any>> = {
  typescript: () => import('@shikijs/langs/typescript'),
  tsx: () => import('@shikijs/langs/tsx'),
  javascript: () => import('@shikijs/langs/javascript'),
  jsx: () => import('@shikijs/langs/jsx'),
  json: () => import('@shikijs/langs/json'),
  jsonc: () => import('@shikijs/langs/jsonc'),
  markdown: () => import('@shikijs/langs/markdown'),
  html: () => import('@shikijs/langs/html'),
  xml: () => import('@shikijs/langs/xml'),
  css: () => import('@shikijs/langs/css'),
  scss: () => import('@shikijs/langs/scss'),
  sass: () => import('@shikijs/langs/sass'),
  less: () => import('@shikijs/langs/less'),
  python: () => import('@shikijs/langs/python'),
  ruby: () => import('@shikijs/langs/ruby'),
  go: () => import('@shikijs/langs/go'),
  rust: () => import('@shikijs/langs/rust'),
  java: () => import('@shikijs/langs/java'),
  kotlin: () => import('@shikijs/langs/kotlin'),
  c: () => import('@shikijs/langs/c'),
  cpp: () => import('@shikijs/langs/cpp'),
  csharp: () => import('@shikijs/langs/csharp'),
  swift: () => import('@shikijs/langs/swift'),
  php: () => import('@shikijs/langs/php'),
  lua: () => import('@shikijs/langs/lua'),
  r: () => import('@shikijs/langs/r'),
  bash: () => import('@shikijs/langs/bash'),
  fish: () => import('@shikijs/langs/fish'),
  yaml: () => import('@shikijs/langs/yaml'),
  toml: () => import('@shikijs/langs/toml'),
  ini: () => import('@shikijs/langs/ini'),
  sql: () => import('@shikijs/langs/sql'),
  graphql: () => import('@shikijs/langs/graphql'),
  proto: () => import('@shikijs/langs/proto'),
  docker: () => import('@shikijs/langs/docker'),
  nix: () => import('@shikijs/langs/nix'),
  zig: () => import('@shikijs/langs/zig'),
  vue: () => import('@shikijs/langs/vue'),
  svelte: () => import('@shikijs/langs/svelte'),
  diff: () => import('@shikijs/langs/diff'),
  make: () => import('@shikijs/langs/make'),
  cmake: () => import('@shikijs/langs/cmake'),
};

async function ensureLang(hl: HighlighterCore, lang: string): Promise<boolean> {
  if (loadedLangs.has(lang)) return true;
  const loader = LANG_LOADERS[lang];
  if (!loader) return false;
  let p = loadingLangs.get(lang);
  if (!p) {
    p = (async () => {
      try {
        const mod: any = await loader();
        await hl.loadLanguage(mod.default);
        loadedLangs.add(lang);
        return true;
      } catch {
        return false;
      }
    })();
    loadingLangs.set(lang, p);
  }
  return p;
}

// Highlight `code` for `lang`, returning Shiki's <pre class="shiki">…</pre> HTML.
// Returns null on any failure or when the language is unsupported, so the caller
// can fall back to a plain, un-highlighted <pre>.
export async function highlightCode(code: string, lang: string): Promise<string | null> {
  const language = String(lang || '').trim();
  if (!language) return null;
  try {
    const hl = await getHighlighter();
    if (!(await ensureLang(hl, language))) return null;
    return hl.codeToHtml(code, {
      lang: language,
      theme: THEME,
      structure: 'classic',
    });
  } catch {
    return null;
  }
}
