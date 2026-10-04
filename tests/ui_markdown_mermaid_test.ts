// REQ-MARKDOWN-MERMAID-32: Mermaid diagram rendering with syntax error fallback in Markdown renderer
//
// RUN: node --test tests/ui_markdown_mermaid_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import esbuild from 'esbuild';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const MARKDOWN_BODY_FILE = path.join(REPO_ROOT, 'src/ui/components/MarkdownBody.tsx');
const TEMP_BUNDLE_PATH = path.join(REPO_ROOT, 'tests/.test-markdown-mermaid-bundle.mjs');

// 1. Source Code Structural Verification
test('MarkdownBody.tsx satisfies REQ-MARKDOWN-MERMAID-32 source specifications', () => {
  assert.ok(fs.existsSync(MARKDOWN_BODY_FILE), 'MarkdownBody.tsx must exist');
  const content = fs.readFileSync(MARKDOWN_BODY_FILE, 'utf8');

  // Verify dynamic getMermaid loader
  assert.match(
    content,
    /export\s+async\s+function\s+getMermaid\(\):\s*Promise<MermaidRenderer\s*\|\s*null>/,
    'MarkdownBody.tsx must define and export getMermaid'
  );
  assert.match(
    content,
    /import\(['"]mermaid['"]\)/,
    'getMermaid must dynamically import "mermaid"'
  );
  assert.match(
    content,
    /suppressErrorRendering:\s*true/,
    'mermaid.initialize must configure suppressErrorRendering: true'
  );
  assert.match(
    content,
    /theme:\s*['"]dark['"]/,
    'mermaid.initialize must configure dark theme'
  );
  assert.match(
    content,
    /securityLevel:\s*['"]loose['"]/,
    'mermaid.initialize must configure securityLevel: loose'
  );

  // Verify query selector for unrendered mermaid blocks
  assert.ok(
    content.includes('.mermaid-block [data-mermaid-rendered="false"]'),
    'useEffect must query .mermaid-block [data-mermaid-rendered="false"]'
  );

  // Verify syntax error handling & fallback
  assert.ok(
    content.includes("data-mermaid-rendered', 'error'") || content.includes('data-mermaid-rendered", "error"'),
    'Syntax error handler must set data-mermaid-rendered="error"'
  );
  assert.ok(
    content.includes('data-debug-id="mermaid-syntax-error-indicator"'),
    'Syntax error handler must render data-debug-id="mermaid-syntax-error-indicator"'
  );
  assert.ok(
    content.includes('Invalid diagram syntax'),
    'Syntax error indicator must display "Invalid diagram syntax"'
  );
  assert.ok(
    content.includes('data-lang="mermaid"'),
    'Raw code fallback must have data-lang="mermaid"'
  );

  // Verify copy button attribute retention
  assert.ok(
    content.includes('data-mermaid-code='),
    'renderBlocks must include data-mermaid-code on .mermaid-block'
  );
  assert.ok(
    content.includes("wrapper?.getAttribute('data-mermaid-code')"),
    'Copy click handler must read data-mermaid-code from wrapper'
  );
});

// Helper to bundle MarkdownBody.tsx for functional testing in Node
async function loadBundledMarkdownBody() {
  await esbuild.build({
    entryPoints: [MARKDOWN_BODY_FILE],
    bundle: true,
    format: 'esm',
    platform: 'node',
    packages: 'external',
    outfile: TEMP_BUNDLE_PATH,
  });
  return import(TEMP_BUNDLE_PATH);
}

// 2. Functional Markdown Rendering Tests
test('renderMarkdown outputs .mermaid-block with data-mermaid-code and data-mermaid-rendered="false"', async () => {
  const mod = await loadBundledMarkdownBody();
  const { renderMarkdown } = mod;

  const rawCode = `graph TD\n    A[Start] --> B{Is valid?}\n    B -->|Yes| C[Render SVG]\n    B -->|No| D[Show raw code]`;
  const markdownSource = `Here is a diagram:\n\n\`\`\`mermaid\n${rawCode}\n\`\`\`\n\nEnd of diagram.`;

  const html = renderMarkdown(markdownSource, false);

  assert.ok(
    html.includes('class="group my-2 overflow-hidden rounded-xl border border-subtle bg-surface mermaid-block"'),
    'Output must include .mermaid-block container'
  );
  assert.ok(
    html.includes('data-mermaid-code='),
    'Output must include data-mermaid-code attribute'
  );
  assert.ok(
    html.includes('data-mermaid-rendered="false"'),
    'Initial container must have data-mermaid-rendered="false"'
  );
  assert.ok(
    html.includes('data-markdown-copy-code="true"'),
    'Output must include copy code button'
  );

  // Check case insensitivity
  const htmlUpper = renderMarkdown('```MERMAID\ngraph LR\n```', false);
  assert.ok(htmlUpper.includes('mermaid-block'), 'Must match MERMAID case-insensitively');

  // Clean up bundle
  if (fs.existsSync(TEMP_BUNDLE_PATH)) {
    fs.unlinkSync(TEMP_BUNDLE_PATH);
  }
});

// 3. Dynamic getMermaid() Module Loader Tests
test('Dynamic getMermaid() initializes with suppressErrorRendering: true and caches promise', async () => {
  const mod = await loadBundledMarkdownBody();
  const { getMermaid, resetMermaidForTesting } = mod;

  // Mock window for Node test environment
  const originalWindow = (globalThis as any).window;
  const originalMermaid = (globalThis as any).mermaid;

  try {
    (globalThis as any).window = {};
    resetMermaidForTesting?.();

    // A. Ambient mermaid test
    let ambientInitConfig: any = null;
    (globalThis as any).mermaid = {
      initialize: (cfg: any) => { ambientInitConfig = cfg; },
      render: async (id: string, code: string) => ({ svg: `<svg id="${id}"></svg>` }),
    };

    const ambientRenderer = await getMermaid();
    assert.ok(ambientRenderer, 'getMermaid must return ambient renderer');
    assert.deepEqual(ambientInitConfig, {
      startOnLoad: false,
      theme: 'dark',
      securityLevel: 'loose',
      suppressErrorRendering: true,
    });

    // B. Dynamic import test (when ambient is not provided)
    delete (globalThis as any).mermaid;
    resetMermaidForTesting?.();

    const dynamicRenderer = await getMermaid();
    assert.ok(dynamicRenderer, 'getMermaid must dynamically load mermaid module');
    assert.equal(typeof dynamicRenderer.render, 'function', 'mermaid must have render function');
  } finally {
    if (originalWindow !== undefined) {
      (globalThis as any).window = originalWindow;
    } else {
      delete (globalThis as any).window;
    }
    if (originalMermaid !== undefined) {
      (globalThis as any).mermaid = originalMermaid;
    } else {
      delete (globalThis as any).mermaid;
    }
    if (fs.existsSync(TEMP_BUNDLE_PATH)) {
      fs.unlinkSync(TEMP_BUNDLE_PATH);
    }
  }
});

// 4. Diagram Rendering and Syntax Error Fallback Tests
test('renderMermaidElement renders SVG on valid syntax and displays fallback on error', async () => {
  const mod = await loadBundledMarkdownBody();
  const { renderMermaidElement, resetMermaidForTesting } = mod;

  const originalWindow = (globalThis as any).window;
  const originalDocument = (globalThis as any).document;
  const originalMermaid = (globalThis as any).mermaid;

  try {
    (globalThis as any).window = {};

    // Mock document
    const elementsById = new Map<string, any>();
    (globalThis as any).document = {
      getElementById: (id: string) => elementsById.get(id) || null,
    };

    // Helper to create a fake DOM node
    function createMockElement(tagName = 'div', attributes: Record<string, string> = {}) {
      const attrs = { ...attributes };
      const children: any[] = [];
      const node: any = {
        tagName: tagName.toUpperCase(),
        attributes: attrs,
        innerHTML: '',
        getAttribute: (name: string) => attrs[name] ?? null,
        setAttribute: (name: string, value: string) => { attrs[name] = String(value); },
        hasAttribute: (name: string) => name in attrs,
        closest: (selector: string) => {
          if (selector === '.mermaid-block') {
            return node.parent || node;
          }
          return null;
        },
        parentNode: null as any,
        removeChild: (child: any) => {
          const idx = children.indexOf(child);
          if (idx !== -1) children.splice(idx, 1);
          child.parentNode = null;
        },
      };
      return node;
    }

    // A. Successful rendering case
    resetMermaidForTesting?.();
    let renderedId = '';
    let renderedCode = '';
    (globalThis as any).mermaid = {
      initialize: () => {},
      render: async (id: string, code: string) => {
        renderedId = id;
        renderedCode = code;
        return { svg: `<svg id="${id}" data-test="rendered"><g></g></svg>` };
      },
    };

    const validBlock = createMockElement('div', {
      class: 'mermaid-block',
      'data-mermaid-code': 'graph TD\nA-->B',
    });
    const validContainer = createMockElement('div', {
      'data-mermaid-rendered': 'false',
    });
    validContainer.parent = validBlock;

    const renderSuccess = await renderMermaidElement(validContainer, 0);
    assert.equal(renderSuccess, true, 'renderMermaidElement must succeed on valid syntax');
    assert.equal(validContainer.getAttribute('data-mermaid-rendered'), 'true', 'Must set data-mermaid-rendered="true"');
    assert.ok(validContainer.innerHTML.includes('<svg'), 'Must inject SVG markup');
    assert.equal(renderedCode, 'graph TD\nA-->B');

    // B. Syntax error fallback case
    resetMermaidForTesting?.();
    (globalThis as any).mermaid = {
      initialize: () => {},
      render: async (_id: string, _code: string) => {
        // Simulate stray element injected by Mermaid on parse error
        const strayEl = createMockElement('div', { id: `d${_id}` });
        const parentDoc = createMockElement('body');
        strayEl.parentNode = parentDoc;
        parentDoc.removeChild = (c: any) => { strayEl.parentNode = null; };
        elementsById.set(`d${_id}`, strayEl);

        throw new Error('Parse error on line 1: Invalid syntax');
      },
    };

    const invalidCode = 'this is not valid mermaid syntax <> & \'"';
    const errorBlock = createMockElement('div', {
      class: 'mermaid-block',
      'data-mermaid-code': invalidCode,
    });
    const errorContainer = createMockElement('div', {
      'data-mermaid-rendered': 'false',
    });
    errorContainer.parent = errorBlock;

    const renderErrorResult = await renderMermaidElement(errorContainer, 1);
    assert.equal(renderErrorResult, false, 'renderMermaidElement must return false on error');
    assert.equal(errorContainer.getAttribute('data-mermaid-rendered'), 'error', 'Must set data-mermaid-rendered="error"');

    // Verify warning badge and raw escaped code fallback
    assert.ok(
      errorContainer.innerHTML.includes('data-debug-id="mermaid-syntax-error-indicator"'),
      'Fallback HTML must include warning badge with data-debug-id="mermaid-syntax-error-indicator"'
    );
    assert.ok(
      errorContainer.innerHTML.includes('Invalid diagram syntax'),
      'Fallback HTML must include "Invalid diagram syntax" text'
    );
    assert.ok(
      errorContainer.innerHTML.includes('<pre class="font-mono text-[12px] leading-relaxed text-primary overflow-x-auto w-full" data-lang="mermaid">'),
      'Fallback HTML must include raw code pre container with data-lang="mermaid"'
    );
    assert.ok(
      errorContainer.innerHTML.includes('this is not valid mermaid syntax &lt;&gt; &amp; &#39;&quot;'),
      'Fallback HTML must escape special characters in raw code'
    );
  } finally {
    if (originalWindow !== undefined) {
      (globalThis as any).window = originalWindow;
    } else {
      delete (globalThis as any).window;
    }
    if (originalDocument !== undefined) {
      (globalThis as any).document = originalDocument;
    } else {
      delete (globalThis as any).document;
    }
    if (originalMermaid !== undefined) {
      (globalThis as any).mermaid = originalMermaid;
    } else {
      delete (globalThis as any).mermaid;
    }
    if (fs.existsSync(TEMP_BUNDLE_PATH)) {
      fs.unlinkSync(TEMP_BUNDLE_PATH);
    }
  }
});

// 5. Copy Button Code Extraction Tests
test('Copy button extracts raw mermaid code across unrendered, rendered, and error states', () => {
  const content = fs.readFileSync(MARKDOWN_BODY_FILE, 'utf8');

  // Verify that copy button handler inspects data-mermaid-code first
  assert.ok(
    content.includes("text = wrapper?.getAttribute('data-mermaid-code')"),
    'Copy click handler must prioritize data-mermaid-code attribute from wrapper'
  );

  // In all states (rendered="false", rendered="true", rendered="error"),
  // the outer .mermaid-block wrapper retains data-mermaid-code="${escapedCode}".
  // Verify that neither renderMermaidElement nor error handler alters data-mermaid-code.
  assert.ok(
    !content.includes("block?.removeAttribute('data-mermaid-code')"),
    'data-mermaid-code must not be removed from .mermaid-block'
  );
});
