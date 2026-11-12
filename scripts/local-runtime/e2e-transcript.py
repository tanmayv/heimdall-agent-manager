#!/usr/bin/env python3
"""Readable digest of a Claude Code session transcript (JSONL on stdin):
one line per assistant text, tool call and tool result, each cut to --width."""
import json, sys

width = int(sys.argv[sys.argv.index('--width') + 1]) if '--width' in sys.argv else 400
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    content = (d.get('message') or {}).get('content')
    if isinstance(content, str):
        print(f"{d.get('type', '?').upper()} {content[:width]!r}")
        continue
    for x in content or []:
        kind = x.get('type')
        if kind == 'text':
            print(f"TEXT {x['text'][:width]!r}")
        elif kind == 'tool_use':
            print(f"CALL {json.dumps(x.get('input'))[:width]}")
        elif kind == 'tool_result':
            r = x.get('content')
            print(f"RES  {(r if isinstance(r, str) else json.dumps(r))[:width]!r}")
