#!/usr/bin/env python3
from __future__ import annotations
import json, os, socket, subprocess, tempfile, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def free_port() -> int:
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def wait_get(url: str, timeout: float = 10) -> None:
    end = time.time() + timeout
    while time.time() < end:
        try:
            urllib.request.urlopen(url, timeout=.5).close(); return
        except Exception:
            time.sleep(.1)
    raise RuntimeError(url)

def req(method: str, url: str, body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    h = {'Content-Type': 'application/json', **(headers or {})}
    r = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=5) as resp:
            raw = resp.read().decode(); return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(); return e.code, json.loads(raw) if raw else {}

def search(base: str, q: str, headers: dict[str, str], types: str = '', limit: int | None = 20):
    query = {'q': q}
    if limit is not None:
        query['limit'] = str(limit)
    if types:
        query['types'] = types
    return req('GET', f'{base}/search?{urllib.parse.urlencode(query)}', headers=headers)

def group(data: dict, typ: str) -> list[dict]:
    for g in data.get('data', {}).get('groups', []):
        if g.get('type') == typ:
            return g.get('hits', [])
    return []

def labels(hits: list[dict]) -> list[str]:
    return [str(h.get('label', '')) for h in hits]

def total_hits(data: dict) -> int:
    return sum(len(g.get('hits', [])) for g in data.get('data', {}).get('groups', []))

def main() -> None:
    hub_bin = Path(os.environ.get('HAM_HUB_BIN', '/tmp/ham-hub-ui18'))
    if not hub_bin.exists():
        raise SystemExit(f'missing HAM_HUB_BIN: {hub_bin}')
    port = free_port(); base = f'http://127.0.0.1:{port}/api/v1'
    alice = {'X-authentik-username': 'alice'}; bob = {'X-authentik-username': 'bob'}
    with tempfile.TemporaryDirectory(prefix='ham-hub-ui18-') as tmp:
        hub = subprocess.Popen([str(hub_bin), '--listen', f'127.0.0.1:{port}', '--db', str(Path(tmp)/'hub.db'), '--logout-url', '/_dev/logout'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            wait_get(f'{base}/health')
            # Create prefix/interior pairs to validate deterministic ranking within a type.
            st, alpha_agent = req('POST', f'{base}/agents', {'name': 'Alpha Agent', 'slug': 'alpha-agent'}, alice); assert st == 201, alpha_agent
            st, beta_agent = req('POST', f'{base}/agents', {'name': 'Beta Alpha', 'slug': 'beta-alpha'}, alice); assert st == 201, beta_agent
            st, project = req('POST', f'{base}/projects', {'name': 'Alpha Project', 'slug': 'alpha-project', 'default_path': tmp, 'vcs_kind': 'none'}, alice); assert st == 201, project
            st, chain = req('POST', f'{base}/task-chains', {'title': 'Alpha Chain', 'kind': 'team_work'}, alice); assert st == 201, chain
            chain_id = chain['data']['chain_id']
            st, task = req('POST', f'{base}/task-chains/{chain_id}/tasks', {'title': 'Alpha Task'}, alice); assert st == 201, task
            st, mem = req('POST', f'{base}/memories', {'title': 'Alpha Memory', 'body': 'Stored preference', 'type': 'fact'}, alice); assert st == 201, mem
            st, art = req('POST', f'{base}/artifacts', {'name': 'Alpha Artifact', 'kind': 'markdown', 'content_type': 'text/markdown', 'content': 'not searched'}, alice); assert st == 201, art

            st, all_alpha = search(base, 'alpha', alice, limit=None); assert st == 200 and all_alpha['page']['limit'] == 20, all_alpha
            for typ in ['agent', 'project', 'task-chain', 'task', 'memory', 'artifact']:
                assert group(all_alpha, typ), (typ, all_alpha)
            assert all_alpha['page']['has_more'] in (False, True), all_alpha
            assert group(all_alpha, 'agent')[0]['label'] == 'Alpha Agent', group(all_alpha, 'agent')
            assert group(all_alpha, 'agent')[0]['score'] >= group(all_alpha, 'agent')[1]['score'], group(all_alpha, 'agent')

            st, upper = search(base, 'ALPHA', alice, types='agent', limit=10); assert st == 200 and labels(group(upper, 'agent'))[:2] == ['Alpha Agent', 'Beta Alpha'], upper
            st, one = search(base, 'a', alice, types='agent', limit=1); assert st == 200 and len(group(one, 'agent')) == 1 and one['page']['has_more'] is True, one
            st, global_one = search(base, 'alpha', alice, limit=1); assert st == 200 and global_one['page']['limit'] == 1 and total_hits(global_one) == 1 and global_one['page']['has_more'] is True, global_one
            st, empty = search(base, '   ', alice); assert st == 200 and empty['data']['groups'] == [], empty
            st, filtered = search(base, 'alpha', alice, types='project', limit=5); assert st == 200 and group(filtered, 'project') and not group(filtered, 'agent'), filtered
            st, bob_result = search(base, 'alpha', bob); assert st == 200 and bob_result['data']['groups'] == [], bob_result
        finally:
            hub.terminate()
            try: hub.wait(timeout=3)
            except subprocess.TimeoutExpired: hub.kill()
    print('PASS: hub UI-18 search real smoke')

if __name__ == '__main__':
    main()
