// REQ-PATH-1/2: a path-style link to any UI route (e.g. a chat artifact link
// https://<host>/library/artifacts/<id>) is rewritten to the matching hash route
// /#<pathname><search> by the inline boot script in index.html, before any relative
// asset URL resolves. Non-UI paths stay untouched, and sign-in started from the
// rewritten page returns to the same view.
//
// RUN: node --test tests/ui_path_route_boot_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

import { currentReturnTo } from '../src/ui/auth/oidcSession.ts';

const INDEX_HTML = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const BOOT_SCRIPT = (() => {
  const match = /<script id="heimdall-path-route-boot">([\s\S]*?)<\/script>/.exec(INDEX_HTML);
  if (!match) throw new Error('index.html must carry the heimdall-path-route-boot script');
  return match[1];
})();

type Boot = { pathname: string; search: string; hash: string; replaced: string | null };

// Runs the boot script against a location built from `href` and returns the
// location it leaves behind (replaceState applied like a browser would).
function boot(href: string): Boot {
  const url = new URL(href);
  let replaced: string | null = null;
  const window = {
    location: { protocol: url.protocol, pathname: url.pathname, search: url.search, hash: url.hash },
    history: {
      state: null,
      replaceState(_state: unknown, _title: string, target: string) {
        replaced = target;
        const next = new URL(target, url);
        window.location.pathname = next.pathname;
        window.location.search = next.search;
        window.location.hash = next.hash;
      },
    },
  };
  vm.runInNewContext(BOOT_SCRIPT, { window });
  return { ...window.location, replaced };
}

test('path-style UI routes are rewritten to the matching hash route', () => {
  const cases: Array<[string, string]> = [
    ['/library/artifacts/art_18e9f8411d78c2db', '/#/library/artifacts/art_18e9f8411d78c2db'],
    ['/library', '/#/library'],
    ['/chains/c1/tasks/t2?view=x', '/#/chains/c1/tasks/t2?view=x'],
    ['/workspace/chains/c1/tasks/t2', '/#/workspace/chains/c1/tasks/t2'],
    ['/conversations/conv_1', '/#/conversations/conv_1'],
    ['/c/conv_1', '/#/c/conv_1'],
    ['/agents/agt_1', '/#/agents/agt_1'],
    ['/issues/iss_1', '/#/issues/iss_1'],
    ['/projects/prj_1/edit', '/#/projects/prj_1/edit'],
    ['/memory/mem_1', '/#/memory/mem_1'],
    ['/shells/sh_1', '/#/shells/sh_1'],
    ['/skills/s1', '/#/skills/s1'],
    ['/actions/new', '/#/actions/new'],
    ['/settings/devices', '/#/settings/devices'],
    ['/home', '/#/home'],
    ['/home?intent=shell', '/#/home?intent=shell'],
    ['/new', '/#/new'],
    ['/new?intent=agent', '/#/new?intent=agent'],
    ['/new?intent=shell', '/#/new?intent=shell'],
    ['/cards', '/#/cards'],
    ['/device/add?code=ABCD-2345', '/#/device/add?code=ABCD-2345'],
    ['/mcp/consent?x=1', '/#/mcp/consent?x=1'],
    ['/setup', '/#/setup'],
    ['/library/artifacts/art_1/', '/#/library/artifacts/art_1/'],
  ];
  for (const [path, expected] of cases) {
    const result = boot(`https://heimdall.example${path}`);
    assert.equal(result.replaced, expected, path);
    assert.equal(result.pathname, '/', path);
  }
});

test('non-UI paths, the root document and existing hash routes are left alone', () => {
  for (const href of [
    'https://heimdall.example/',
    'https://heimdall.example/index.html',
    'https://heimdall.example/?a=1',
    'https://heimdall.example/api/v1/auth/callback?code=x&state=y',
    'https://heimdall.example/api/v1/auth/login?return_to=%2F',
    'https://heimdall.example/assets/index-abc.js',
    'https://heimdall.example/p/sh_1/',
    'https://heimdall.example/library-old/x',
    'https://heimdall.example/unknown/route',
    'https://heimdall.example/#/library/artifacts/art_1',
    'https://heimdall.example/library/artifacts/art_1#/chains/c1',
    'file:///opt/heimdall/library/artifacts/art_1',
  ]) {
    assert.equal(boot(href).replaced, null, href);
  }
});

test('sign-in started from a path-style link returns to the same view', () => {
  const result = boot('https://heimdall.example/library/artifacts/art_1');
  assert.equal(currentReturnTo(result), '/#/library/artifacts/art_1');
  const chain = boot('https://heimdall.example/chains/c1/tasks/t2?view=x');
  assert.equal(currentReturnTo(chain), '/#/chains/c1/tasks/t2?view=x');
});
