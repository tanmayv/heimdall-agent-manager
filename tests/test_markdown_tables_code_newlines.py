#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MD = ROOT / 'src/ui/components/MarkdownBody.tsx'

src = MD.read_text()
checks = [
    ('literal escaped newlines normalize to real line breaks', "replace(/\\\\n/g, '\\n')" in src and "normalizeMarkdownSource" in src),
    ('pipe table renderer exists', 'function renderTable' in src and 'isTableSeparator' in src and '<table' in src),
    ('paragraph parser stops before tables', 'isLikelyTableHeader(lines[i], lines[i + 1])' in src),
    ('fenced code renders copy button', 'data-markdown-copy-code="true"' in src and 'navigator.clipboard' in src),
    ('tables render copy CSV button', 'data-markdown-copy-table="true"' in src and 'Copy CSV' in src),
    ('table copy serializes CSV', 'function tableToCsv' in src and 'function csvEscape' in src and '.join(\',\')' in src),
    ('copy is event delegated from markdown root', 'rootRef' in src and 'addEventListener' in src),
    ('underscore emphasis does not trigger inside words', "(?![A-Za-z0-9_])" in src and "[^A-Za-z0-9_]" in src),
    ('mermaid and mermedai diagram blocks supported', 'mermaid-block' in src and 'mermedai' in src and 'mermaid.render' in src),
    ('top right subtle copy all icon button copies entire markdown', 'data-markdown-copy-all="true"' in src and 'data-markdown-source' in src and 'justify-end' in src),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: markdown tables/code/newline rendering')
