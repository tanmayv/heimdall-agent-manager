#!/usr/bin/env python3
"""Regression test for Markdown heading styling and UI resource ID auto-linking.

Requirements:
- REQ-MD-HEADINGS-1: Distinct font sizes and theme-token colors for H1, H2, H3 headings.
- REQ-MD-IDLINK-1: Bare Heimdall resource ID auto-linking for agt_, iss_, inst_, mem_, proj_, chain_, act_, sh_ to hash routes with link exclusion guards.
"""

from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MARKDOWN_BODY = ROOT / 'src/ui/components/MarkdownBody.tsx'
STYLES_CSS = ROOT / 'src/ui/styles.css'
TOKENS_CSS = ROOT / 'src/ui/tokens.css'


def test_markdown_body_headings_source():
    assert MARKDOWN_BODY.exists(), f"MarkdownBody.tsx not found at {MARKDOWN_BODY}"
    src = MARKDOWN_BODY.read_text(encoding='utf-8')

    # Verify heading level 1, 2, 3 have distinct tags and classes
    assert 'HEADING_STYLES' in src, "Missing HEADING_STYLES configuration in MarkdownBody.tsx"
    assert "tag: 'h1'" in src and 'text-xl' in src and 'text-accent' in src, \
        "H1 must render <h1> with text-xl and text-accent"
    assert "tag: 'h2'" in src and 'text-lg' in src and 'text-primary' in src, \
        "H2 must render <h2> with text-lg and text-primary"
    assert "tag: 'h3'" in src and 'text-base' in src and 'text-muted' in src, \
        "H3 must render <h3> with text-base and text-muted"

    # Verify headings are no longer rendered with uniform h${Math.min(6, level + 2)} and uniform classes
    assert "h${Math.min(6, level + 2)}" not in src, "Old uniform heading tag generation must be removed"


def test_styles_css_headings():
    assert STYLES_CSS.exists(), f"styles.css not found at {STYLES_CSS}"
    css = STYLES_CSS.read_text(encoding='utf-8')

    # REQ-MD-HEADINGS-1: .markdown h1, h2, h3 must have distinct sizes and theme colors
    assert '.markdown h1' in css, "Missing .markdown h1 selector in styles.css"
    assert '.markdown h2' in css, "Missing .markdown h2 selector in styles.css"
    assert '.markdown h3' in css, "Missing .markdown h3 selector in styles.css"

    h1_block = re.search(r'\.markdown h1\s*\{([^}]+)\}', css)
    assert h1_block, "Could not find .markdown h1 rule block in styles.css"
    assert 'var(--color-accent)' in h1_block.group(1), "H1 must use var(--color-accent)"

    h2_block = re.search(r'\.markdown h2\s*\{([^}]+)\}', css)
    assert h2_block, "Could not find .markdown h2 rule block in styles.css"
    assert 'var(--color-text-primary)' in h2_block.group(1), "H2 must use var(--color-text-primary)"

    h3_block = re.search(r'\.markdown h3\s*\{([^}]+)\}', css)
    assert h3_block, "Could not find .markdown h3 rule block in styles.css"
    assert 'var(--color-text-muted)' in h3_block.group(1), "H3 must use var(--color-text-muted)"


def test_theme_adaptability():
    assert TOKENS_CSS.exists(), f"tokens.css not found at {TOKENS_CSS}"
    tokens = TOKENS_CSS.read_text(encoding='utf-8')

    # Verify that theme tokens vary across themes for dynamic adaptation
    assert '[data-theme="default-dark"]' in tokens, "Missing default-dark theme in tokens.css"
    assert '[data-theme="catppuccin-mocha"]' in tokens, "Missing catppuccin-mocha theme in tokens.css"


def test_markdown_body_resource_id_source():
    src = MARKDOWN_BODY.read_text(encoding='utf-8')

    # Check 8 resource ID prefixes
    prefixes = ['agt_', 'iss_', 'inst_', 'mem_', 'proj_', 'chain_', 'act_', 'sh_']
    for p in prefixes:
        assert p in src, f"Missing resource ID prefix {p} in MarkdownBody.tsx"

    assert 'RESOURCE_ID_PREFIXES' in src, "Missing RESOURCE_ID_PREFIXES in MarkdownBody.tsx"
    assert 'RESOURCE_TYPE_CONFIG' in src, "Missing RESOURCE_TYPE_CONFIG in MarkdownBody.tsx"
    assert 'autolinkResourceIds' in src, "Missing autolinkResourceIds export in MarkdownBody.tsx"

    # Check anchor attributes
    assert 'data-resource-id=' in src, "Missing data-resource-id attribute in generated links"
    assert 'data-resource-type=' in src, "Missing data-resource-type attribute in generated links"
    assert 'font-mono text-accent underline decoration-accent/40 hover:decoration-accent' in src, \
        "Missing requested anchor classes in generated resource links"

    # Check click listener for hash route navigation
    assert 'resourceAnchor' in src or 'data-resource-id' in src, "Missing resource link click handling"
    assert "href.startsWith('#/')" in src or 'window.location.hash' in src, \
        "Click listener must support hash route navigation"


def test_functional_rendering():
    node_test_script = r"""
    import { renderMarkdown, autolinkResourceIds } from './tests/test-markdown-body.mjs';

    function assert(cond, msg) {
      if (!cond) {
        throw new Error(msg);
      }
    }

    // --- 1. Heading tests ---
    const h1 = renderMarkdown('# Heading 1', false);
    assert(h1.includes('<h1 class="mt-3 text-xl font-bold text-accent">Heading 1</h1>'), 'H1 rendering failed: ' + h1);

    const h2 = renderMarkdown('## Heading 2', false);
    assert(h2.includes('<h2 class="mt-2.5 text-lg font-semibold text-primary">Heading 2</h2>'), 'H2 rendering failed: ' + h2);

    const h3 = renderMarkdown('### Heading 3', false);
    assert(h3.includes('<h3 class="mt-2 text-base font-medium text-muted">Heading 3</h3>'), 'H3 rendering failed: ' + h3);

    // --- 2. Resource ID autolinking for all 8 types ---
    const ids = [
      { id: 'agt_worker_1', route: '#/agents/agt_worker_1', type: 'agent' },
      { id: 'iss_bug_99', route: '#/issues/iss_bug_99', type: 'issue' },
      { id: 'inst_conv_123', route: '#/conversations/inst_conv_123', type: 'conversation' },
      { id: 'mem_fact_4', route: '#/memory/mem_fact_4', type: 'memory' },
      { id: 'proj_alpha_7', route: '#/projects/proj_alpha_7', type: 'project' },
      { id: 'chain_deploy_88', route: '#/chains/chain_deploy_88', type: 'chain' },
      { id: 'act_run_5', route: '#/actions/act_run_5', type: 'action' },
      { id: 'sh_term_42', route: '#/shells/sh_term_42', type: 'shell' },
    ];

    for (const item of ids) {
      const rendered = renderMarkdown(`Check ${item.id} here.`, false);
      const expected = `<a href="${item.route}" data-resource-id="${item.id}" data-resource-type="${item.type}" class="font-mono text-accent underline decoration-accent/40 hover:decoration-accent">${item.id}</a>`;
      assert(rendered.includes(expected), `Failed autolinking for ${item.id}. Got: ${rendered}`);
    }

    // --- 3. Link exclusion guards ---
    // (a) Pre-existing markdown web link with ID as label
    const mdWebLink = renderMarkdown('[agt_123](https://example.com)', false);
    assert(mdWebLink.includes('<a href="https://example.com" target="_blank" rel="noreferrer" class="text-accent underline decoration-accent/40 hover:decoration-accent">agt_123</a>'), 'Markdown link label should not be double-wrapped: ' + mdWebLink);
    assert(!mdWebLink.includes('data-resource-id'), 'Markdown link label should not have data-resource-id: ' + mdWebLink);

    // (b) Pre-existing markdown web link with ID in URL
    const mdWebUrl = renderMarkdown('[My Link](https://example.com/agt_123)', false);
    assert(mdWebUrl.includes('href="https://example.com/agt_123"'), 'URL should preserve ID: ' + mdWebUrl);
    assert(!mdWebUrl.includes('data-resource-id'), 'URL ID should not be double-wrapped: ' + mdWebUrl);

    // (c) Pre-existing hash link
    const mdHashLink = renderMarkdown('[My Chain](#/chains/chain_123)', false);
    assert(mdHashLink.includes('href="#/chains/chain_123"'), 'Hash link preserved: ' + mdHashLink);
    assert(!mdHashLink.includes('data-resource-id'), 'Hash link should not have data-resource-id: ' + mdHashLink);

    // (d) Pre-existing HTML <a> tag
    const rawAnchor = autolinkResourceIds('<a href="#/custom">inst_123</a>');
    assert(rawAnchor === '<a href="#/custom">inst_123</a>', 'Existing <a> tag should be untouched: ' + rawAnchor);

    // (e) Inside code block
    const fencedCode = renderMarkdown("```\nconst x = agt_123;\n```", false);
    assert(!fencedCode.includes('data-resource-id'), 'Code block should not autolink: ' + fencedCode);

    // (f) Inside inline code
    const inlineCode = renderMarkdown('Use `agt_123` here', false);
    assert(!inlineCode.includes('data-resource-id'), 'Inline code should not autolink: ' + inlineCode);
    assert(inlineCode.includes('>agt_123</code>'), 'Inline code tag missing: ' + inlineCode);

    // (g) Non-matching tokens (word boundaries)
    const nonIds = renderMarkdown('my_agt_123 otherinst_456 inst_ done', false);
    assert(!nonIds.includes('data-resource-id'), 'Non-matching IDs should not autolink: ' + nonIds);

    console.log("FUNCTIONAL_ALL_PASSED");
    """

    # Bundle MarkdownBody for testing
    bundle_cmd = [
        str(ROOT / 'node_modules/.bin/esbuild'),
        'src/ui/components/MarkdownBody.tsx',
        '--bundle',
        '--platform=node',
        '--format=esm',
        '--packages=external',
        '--outfile=tests/test-markdown-body.mjs',
    ]
    subprocess.run(bundle_cmd, cwd=ROOT, check=True, capture_output=True)

    try:
        res = subprocess.run(['node', '--input-type=module', '-e', node_test_script], cwd=ROOT, capture_output=True, text=True)
        assert res.returncode == 0, f"Functional test failed with exit code {res.returncode}:\nStdout: {res.stdout}\nStderr: {res.stderr}"
        assert "FUNCTIONAL_ALL_PASSED" in res.stdout, f"Expected FUNCTIONAL_ALL_PASSED in output: {res.stdout}"
    finally:
        temp_bundle = ROOT / 'tests/test-markdown-body.mjs'
        if temp_bundle.exists():
            temp_bundle.unlink()


def main():
    print("Running Markdown headings and resource ID auto-linking tests...")
    test_markdown_body_headings_source()
    print("PASS: MarkdownBody.tsx heading source checks (H1, H2, H3 distinct tags and classes)")
    test_styles_css_headings()
    print("PASS: styles.css heading rules (.markdown h1/h2/h3 mapped to theme tokens)")
    test_theme_adaptability()
    print("PASS: Theme adaptability in tokens.css")
    test_markdown_body_resource_id_source()
    print("PASS: MarkdownBody.tsx resource ID auto-linking source checks")
    test_functional_rendering()
    print("PASS: Functional rendering tests (H1-H3, all 8 resource types, link exclusion guards, code preservation)")
    print("ALL TESTS PASSED: REQ-MD-HEADINGS-1, REQ-MD-IDLINK-1")


if __name__ == '__main__':
    main()
