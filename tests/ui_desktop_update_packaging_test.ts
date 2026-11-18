import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const source = fs.readFileSync(new URL('../scripts/release/desktop-update-policy.cjs', import.meta.url), 'utf8');
function hook(env: Record<string, string> = {}) {
  const module = { exports: null as any };
  vm.runInNewContext(source, { module, exports: {}, require, process: { env } });
  return module.exports;
}
function context(directory: string, platform = 'win32', targets = ['nsis']) {
  return { appOutDir: directory, electronPlatformName: platform, targets: targets.map(name => ({ name })),
    packager: { appInfo: { version: '1.2.4', productFilename: 'Ninjy' }, config: { forceCodeSigning: true },
      platformSpecificBuildOptions: { publisherName: ['Fixture Publisher'], verifyUpdateCodeSignature: true } } };
}

test('unsigned manual builds disable updater; signed Windows packaging requires publisher, credentials and NSIS only', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ninjy-update-policy-'));
  try {
    const ctx = context(directory);
    await hook()(ctx);
    const marker = () => JSON.parse(fs.readFileSync(path.join(directory, 'resources/desktop-update-policy.json'), 'utf8'));
    assert.equal(marker().updatesEnabled, false);
    await assert.rejects(hook({ HEIMDALL_DESKTOP_SIGNED_RELEASE: '1' })(ctx), /publisher/);
    const env = { HEIMDALL_DESKTOP_SIGNED_RELEASE: '1', HEIMDALL_WINDOWS_PUBLISHER_NAME: 'Fixture Publisher', CSC_LINK: 'fixture-not-a-certificate', CSC_KEY_PASSWORD: 'fixture-not-a-password' };
    await hook(env)(ctx); assert.deepEqual(marker().publisherName, ['Fixture Publisher']); assert.equal(marker().updatesEnabled, true);
    await assert.rejects(hook(env)(context(directory, 'win32', ['portable'])), /only the NSIS/);
    await assert.rejects(hook(env)(context(directory, 'win32', ['nsis', 'portable'])), /only the NSIS/);
    await assert.rejects(hook(env)({ ...ctx, packager: { ...ctx.packager, config: { forceCodeSigning: false } } }), /signing access/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('macOS signed marker requires ZIP, forced signing, notarization inputs and numeric release version', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ninjy-update-policy-'));
  try {
    const ctx = context(directory, 'darwin', ['dmg', 'zip']);
    const env = { HEIMDALL_DESKTOP_SIGNED_RELEASE: '1', CSC_NAME: 'Fixture Identity', APPLE_ID: 'fixture', APPLE_APP_SPECIFIC_PASSWORD: 'fixture', APPLE_TEAM_ID: 'fixture' };
    await assert.rejects(hook({ HEIMDALL_DESKTOP_SIGNED_RELEASE: '1' })(ctx), /requires CSC_NAME/);
    await hook(env)(ctx);
    const marker = JSON.parse(fs.readFileSync(path.join(directory, 'Ninjy.app/Contents/Resources/desktop-update-policy.json'), 'utf8'));
    assert.equal(marker.updatesEnabled, true); assert.equal(marker.distribution, 'mac-app');
    await assert.rejects(hook(env)(context(directory, 'darwin', ['mas'])), /ZIP/);
    ctx.packager.appInfo.version = '1.2.4-beta.1'; await assert.rejects(hook(env)(ctx), /numeric/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('builder and release workflows parse and preserve signing/promotion validation wiring', () => {
  const { load } = require('js-yaml');
  const builder = load(fs.readFileSync(new URL('../electron-builder.yml', import.meta.url), 'utf8'));
  assert.equal(builder.win.verifyUpdateCodeSignature, true);
  assert.equal(builder.afterPack, 'scripts/release/desktop-update-policy.cjs');
  for (const name of ['release-local-binaries.yml', 'promote-release.yml']) {
    const text = fs.readFileSync(new URL(`../.github/workflows/${name}`, import.meta.url), 'utf8');
    assert.ok(load(text).jobs); assert.match(text, /validate-desktop-updates\.py/);
  }
});

test('REQ-DESKTOP-BUILD-1: package only the Electron shell and exclude browser dependencies without removing updater runtime', () => {
  const { load } = require('js-yaml');
  const { FileMatcher, getNodeModuleFileMatcher } = require('app-builder-lib/out/fileMatcher.js');
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const builder = load(fs.readFileSync(path.join(root, 'electron-builder.yml'), 'utf8'));
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json'), 'utf8'));
  const stat = { isDirectory: () => false };
  const shell = new FileMatcher(root, root, (value: string) => value, builder.files).createFilter();
  for (const file of ['electron-dist/main.cjs', 'electron-dist/preload.cjs', 'electron-dist/icon.png', 'package.json']) {
    assert.equal(shell(path.join(root, file), stat), true, file);
  }
  for (const file of ['dist/index.html', 'dist/assets/main.js', 'dist/heimdall-local-linux-amd64.tar.gz']) {
    assert.equal(shell(path.join(root, file), stat), false, file);
  }

  // Use electron-builder's own module matcher: node_modules is collected separately
  // from app files, and only negative file patterns apply to that collection.
  const modules = getNodeModuleFileMatcher(root, root, (value: string) => value, {}, {
    config: builder, debugLogger: { isEnabled: false },
  }).createFilter();
  const included = (file: string) => modules(path.join(root, file), stat);
  const browserPackages = [
    ...Object.keys(manifest.dependencies).filter(name => name !== 'electron-updater'),
    '@shikijs/core', 'cytoscape', 'cytoscape-cose-bilkent', 'd3', 'd3-array',
    'dagre-d3-es', 'katex', 'khroma', 'langium',
  ];
  for (const name of browserPackages) {
    assert.equal(included('node_modules/' + name + '/package.json'), false, name);
    assert.equal(included('node_modules/' + name + '/dist/index.js'), false, name);
  }

  // Follow the locked dependency graph, including nested version overrides,
  // so an exclusion cannot silently break electron-updater at runtime.
  const seen = new Set<string>();
  function checkRuntime(location: string) {
    if (seen.has(location)) return;
    seen.add(location);
    assert.equal(included(location + '/package.json'), true, location);
    assert.equal(included(location + '/out/index.js'), true, location);
    for (const name of Object.keys(lock.packages[location].dependencies ?? {})) {
      let parent = location;
      while (!lock.packages[path.posix.join(parent, 'node_modules', name)]) {
        assert.notEqual(parent, '.', 'missing locked runtime dependency: ' + name);
        parent = path.posix.dirname(parent);
      }
      checkRuntime(path.posix.join(parent, 'node_modules', name));
    }
  }
  checkRuntime('node_modules/electron-updater');
  assert.ok(seen.size > 1, 'must check the updater transitive dependencies');
});

test('REQ-DESKTOP-BUILD-1: desktop scripts and release jobs compile Electron while preserving the Nix web build', () => {
  const { load } = require('js-yaml');
  const manifest = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(manifest.scripts.build, 'npm run typecheck && vite build && npm run build:electron');
  for (const [target, args] of Object.entries({ mac: '--mac dmg', win: '--win nsis --x64', linux: '--linux AppImage deb' })) {
    assert.equal(manifest.scripts['dist:' + target], 'npm run build:electron && electron-builder ' + args);
  }
  const workflow = load(fs.readFileSync(new URL('../.github/workflows/release-local-binaries.yml', import.meta.url), 'utf8'));
  const desktopSteps = Object.values(workflow.jobs).flatMap((job: any) => job.steps ?? [])
    .filter((step: any) => /npx electron-builder --/.test(step.run ?? ''));
  assert.equal(desktopSteps.length, 3, 'cover macOS, Linux and Windows desktop release steps');
  for (const step of desktopSteps as any[]) {
    assert.match(step.run, /^\s*npm run build:electron\s*$/m, step.name);
    assert.doesNotMatch(step.run, /^\s*npm run build\s*$/m, step.name);
    assert.ok(step.run.indexOf('npm run build:electron') < step.run.indexOf('npx electron-builder'), step.name);
  }
});
