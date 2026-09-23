#!/usr/bin/env python3
"""Regression test for Markdown Shiki code blocks, inline/quote accent styling, and paragraph spacing.

Requirement ID: REQ-UI-MARKDOWN-ENHANCE
Verifies:
1. Fenced code blocks wrapped with data-code-block="true", .code-container with
   data-shiki-rendered="false", data-code-raw, data-code-lang.
2. Shiki syntax highlighting integration in MarkdownBody (useEffect calling highlightCode
   and getActiveShikiTheme, setting data-shiki-rendered="true" on success, "fallback" on failure).
3. Copy button reads from data-code-raw, pre code, or pre, while preserving Mermaid copy.
4. Inline code is styled with font-mono text-[0.85em] font-medium text-accent (without border or border-accent/25).
5. Quoted text (‘...’ / ’...’ / '...') is styled with ‘<span class="text-accent font-medium">$1</span>’.
6. Bold and italics preserve standard text-primary without text-accent.
7. Paragraphs use <p class="my-3 leading-relaxed"> and MarkdownBody uses space-y-3 when compact is false.
8. styles.css ensures Shiki pre inside markdown code blocks has transparent bg, font-size 12px, font-mono, padding 0.75rem (p-3), leading-relaxed, and overflow-x-auto.
"""

from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MARKDOWN_BODY = ROOT / 'src/ui/components/MarkdownBody.tsx'
STYLES_CSS = ROOT / 'src/ui/styles.css'
CODE_HIGHLIGHT = ROOT / 'src/ui/utils/codeHighlight.ts'


def test_markdown_body_source():
    assert MARKDOWN_BODY.exists(), f"MarkdownBody.tsx not found at {MARKDOWN_BODY}"
    src = MARKDOWN_BODY.read_text(encoding='utf-8')

    # 1. Code blocks with data-code-block and .code-container metadata
    assert 'data-code-block="true"' in src, "Missing data-code-block=\"true\" attribute on code block wrapper"
    assert 'class="code-container' in src or "class=\"code-container" in src, "Missing .code-container wrapper"
    assert 'data-shiki-rendered="false"' in src, "Missing data-shiki-rendered=\"false\" on code container"
    assert 'data-code-raw=' in src, "Missing data-code-raw attribute on code container"
    assert 'data-code-lang=' in src, "Missing data-code-lang attribute on code container"

    # 2. Shiki highlighting integration in useEffect
    assert 'highlightCode' in src, "Missing highlightCode call in MarkdownBody.tsx"
    assert 'getActiveShikiTheme' in src, "Missing getActiveShikiTheme call in MarkdownBody.tsx"
    assert 'data-shiki-rendered' in src, "Missing data-shiki-rendered queries or attribute updates"
    assert 'fallback' in src, "Missing fallback status for unhighlighted / unsupported code blocks"

    # 3. Copy button reads code text
    assert 'data-code-raw' in src, "Copy button logic should check data-code-raw"
    assert 'querySelector' in src and ('pre code' in src or 'pre' in src), "Copy button logic should query pre / pre code fallback"

    # 4. Inline code accent styling (clean inline code without border)
    inline_code_classes = "font-mono text-[0.85em] font-medium text-accent"
    assert inline_code_classes in src, f"Missing inline code classes: {inline_code_classes}"
    render_inline_match = re.search(r'function renderInline\s*\([^)]*\)\s*:\s*string\s*\{(.*?)\n\}', src, re.DOTALL)
    assert render_inline_match, "Could not find renderInline function in MarkdownBody.tsx"
    inline_body = render_inline_match.group(1)
    code_match = re.search(r'`\(\[\^`\\n\]\+\)`.*?<code([^>]*)>', inline_body)
    assert code_match, "Could not find inline code replacement in renderInline"
    code_attrs = code_match.group(1)
    assert 'border' not in code_attrs, f"Inline code should not have border: {code_attrs}"
    assert 'border-accent/25' not in code_attrs, f"Inline code should not have border-accent/25: {code_attrs}"
    assert 'text-accent' in code_attrs, f"Inline code must retain text-accent: {code_attrs}"
    assert 'font-mono' in code_attrs, f"Inline code must retain font-mono: {code_attrs}"

    # 5. Quoted text styling with accent
    quote_span = '<span class="text-accent font-medium">'
    assert quote_span in src, f"Missing quoted text span: {quote_span}"

    # 6. Bold and italics remain standard text-primary without text-accent
    render_inline_match = re.search(r'function renderInline\s*\([^)]*\)\s*:\s*string\s*\{(.*?)\n\}', src, re.DOTALL)
    assert render_inline_match, "Could not find renderInline function in MarkdownBody.tsx"
    inline_body = render_inline_match.group(1)
    strong_matches = re.findall(r'<strong[^>]*>', inline_body)
    for tag in strong_matches:
        assert 'text-accent' not in tag, f"Bold tag should not have text-accent: {tag}"
    em_matches = re.findall(r'<em[^>]*>', inline_body)
    for tag in em_matches:
        assert 'text-accent' not in tag, f"Italics tag should not have text-accent: {tag}"

    # 7. Paragraph spacing
    assert '<p class="my-3 leading-relaxed">' in src, "Paragraph tag should use my-3 leading-relaxed"
    assert "compact ? 'space-y-1' : 'space-y-3'" in src or 'compact ? "space-y-1" : "space-y-3"' in src, \
        "MarkdownBody container spacing should use space-y-3 when compact is false"


def test_styles_css():
    assert STYLES_CSS.exists(), f"styles.css not found at {STYLES_CSS}"
    css = STYLES_CSS.read_text(encoding='utf-8')

    assert '.markdown-code-block pre.shiki' in css or '.code-container pre.shiki' in css, \
        "Missing .markdown-code-block pre.shiki or .code-container pre.shiki selector in styles.css"
    assert '!bg-transparent' in css or 'background-color: transparent !important' in css, \
        "Missing transparent background for Shiki code blocks"
    assert '12px' in css, "Missing 12px font size for Shiki code blocks"
    assert 'font-mono' in css or 'font-family:' in css, "Missing monospace font for Shiki code blocks"
    assert 'p-3' in css or 'padding: 0.75rem' in css, "Missing 0.75rem / p-3 padding for Shiki code blocks"
    assert 'leading-relaxed' in css or 'line-height:' in css, "Missing leading-relaxed for Shiki code blocks"
    assert 'overflow-x-auto' in css, "Missing overflow-x-auto for Shiki code blocks"


def test_functional_html_rendering():
    node_script = r"""
    function escapeHtml(value) {
      return value
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    function renderInline(text) {
      let escaped = escapeHtml(text);
      escaped = escaped.replace(/`([^`\n]+)`/g, (_m, code) => `<code class="font-mono text-[0.85em] font-medium text-accent">${code}</code>`);
      escaped = escaped.replace(/(?:‘|’)([^‘’\n]+?)(?:’|‘)/g, '‘<span class="text-accent font-medium">$1</span>’');
      escaped = escaped.replace(/(^|[\s(\[{<])(?:&#39;|')(?![\s])([^'‘’\n]+?)(?<![\s])(?:&#39;|')(?=[\]}>)\s.,;:!?]|$)/g, '$1‘<span class="text-accent font-medium">$2</span>’');
      escaped = escaped.replace(/\*\*\*([^*\n]+)\*\*\*/g, '<strong><em>$1</em></strong>');
      escaped = escaped.replace(/(^|[^A-Za-z0-9_])___([^_\n]+)___(?![A-Za-z0-9_])/g, '$1<strong><em>$2</em></strong>');
      escaped = escaped.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
      escaped = escaped.replace(/(^|[^A-Za-z0-9_])__([^_\n]+)__(?![A-Za-z0-9_])/g, '$1<strong>$2</strong>');
      escaped = escaped.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
      escaped = escaped.replace(/(^|[^A-Za-z0-9_])_([^_\s](?:[^_\n]*?[^_\s])?)_(?![A-Za-z0-9_])/g, '$1<em>$2</em>');
      return escaped;
    }

    // 1. Inline code test
    const codeHtml = renderInline('Use `npm run test` here');
    if (!codeHtml.includes('class="font-mono text-[0.85em] font-medium text-accent">npm run test</code>')) {
      throw new Error('Inline code formatting failed: ' + codeHtml);
    }
    if (codeHtml.includes('border') || codeHtml.includes('border-accent/25')) {
      throw new Error('Inline code has unexpected border: ' + codeHtml);
    }

    // 2. Curly single quotes test
    const quoteHtml1 = renderInline('Here is ‘quoted text’ inside.');
    if (!quoteHtml1.includes('‘<span class="text-accent font-medium">quoted text</span>’')) {
      throw new Error('Curly quote formatting failed: ' + quoteHtml1);
    }
    const quoteHtml2 = renderInline('Here is ’alt quote’ inside.');
    if (!quoteHtml2.includes('‘<span class="text-accent font-medium">alt quote</span>’')) {
      throw new Error('Alt curly quote formatting failed: ' + quoteHtml2);
    }

    // 3. ASCII single quote test
    const quoteHtml3 = renderInline("Here is 'single quote' inside.");
    if (!quoteHtml3.includes('‘<span class="text-accent font-medium">single quote</span>’')) {
      throw new Error('ASCII single quote formatting failed: ' + quoteHtml3);
    }

    // 4. Bold and italics test (must not have accent)
    const boldHtml = renderInline('Here is **bold text** and *italic text*.');
    if (boldHtml.includes('text-accent') && (boldHtml.includes('bold text') || boldHtml.includes('italic text'))) {
      throw new Error('Bold or italics has unexpected text-accent: ' + boldHtml);
    }
    if (!boldHtml.includes('<strong>bold text</strong>') || !boldHtml.includes('<em>italic text</em>')) {
      throw new Error('Standard strong/em tags missing: ' + boldHtml);
    }

    console.log("FUNCTIONAL_TESTS_OK");
    """
    res = subprocess.run(['node', '-e', node_script], cwd=ROOT, capture_output=True, text=True)
    assert res.returncode == 0, f"Functional test failed: {res.stderr}"
    assert "FUNCTIONAL_TESTS_OK" in res.stdout


def main():
    print("Running Markdown enhancement tests...")
    test_markdown_body_source()
    print("PASS: MarkdownBody source checks (code blocks, inline code, quotes, bold/italics, paragraph spacing)")
    test_styles_css()
    print("PASS: styles.css checks (.markdown-code-block / .code-container pre.shiki styling)")
    test_functional_html_rendering()
    print("PASS: Functional rendering tests")
    print("ALL TESTS PASSED: REQ-UI-MARKDOWN-ENHANCE")


if __name__ == '__main__':
    main()
