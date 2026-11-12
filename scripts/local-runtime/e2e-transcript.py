#!/usr/bin/env python3
"""Claude Code session transcript (JSONL on stdin) helpers for local E2E runs.

  e2e-transcript.py [--width N]   readable digest: one line per assistant text,
                                  tool call and tool result, each cut to N chars
  e2e-transcript.py --errors      the ham-ctl replies with "ok":false, one per line
  e2e-transcript.py --attach      the commands that attach a project or directory
                                  (ham-ctl ... --project, chain directory set)
"""
import json, re, sys

ATTACH = re.compile(r'ham-ctl\b[^\n|;&]*(--project\b|\bdirectory\s+set\b|chain\.directory\.set)')
ERROR = re.compile(r'\{"v":\s*1,\s*"id":\s*"ham-ctl-agent",\s*"ok":\s*false[^\n]*')


def items():
    for line in sys.stdin:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        content = (d.get('message') or {}).get('content')
        if isinstance(content, str):
            yield d.get('type', '?').upper(), content
            continue
        for x in content or []:
            kind = x.get('type')
            if kind == 'text':
                yield 'TEXT', x['text']
            elif kind == 'tool_use':
                yield 'CALL', json.dumps(x.get('input'))
                if isinstance(x.get('input'), dict) and 'command' in x['input']:
                    yield 'CMD', str(x['input']['command'])
            elif kind == 'tool_result':
                r = x.get('content')
                if isinstance(r, list):
                    r = '\n'.join(str(p.get('text', '')) for p in r if isinstance(p, dict))
                yield 'RES', str(r)


if '--errors' in sys.argv:
    for kind, text in items():
        if kind == 'RES':
            for m in ERROR.finditer(text):
                print(m.group(0)[:400])
elif '--attach' in sys.argv:
    for kind, text in items():
        if kind == 'CMD' and ATTACH.search(text):
            print(text[:400].replace('\n', ' '))
else:
    width = int(sys.argv[sys.argv.index('--width') + 1]) if '--width' in sys.argv else 400
    for kind, text in items():
        if kind != 'CMD':
            print(f'{kind:4} {text[:width]!r}')
