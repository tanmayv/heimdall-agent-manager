/* Run: node --test flow-resume.test.mjs */
import test from 'node:test';
import assert from 'node:assert/strict';
import { flowRedirectTarget } from './flow-resume.js';

const O = 'https://auth.brolabs.ai';
const AUTH = '/application/o/authorize/?client_id=abc&response_type=code&state=s1';
const q = (next) => `?next=${encodeURIComponent(next)}&flow=x`;

test('normal login: non-root redirect is unchanged', () => {
  assert.equal(flowRedirectTarget('/application/o/authorize/?client_id=abc', q(AUTH), O), '/application/o/authorize/?client_id=abc');
  assert.equal(flowRedirectTarget('https://app.example.com/cb', q(AUTH), O), 'https://app.example.com/cb');
});

test('add-account: root redirect resumes authorize without prompt=login', () => {
  const next = AUTH + '&prompt=login';
  for (const to of ['/', '/if/user/', O + '/', O + '/if/user/', undefined]) {
    assert.equal(flowRedirectTarget(to, q(next), O), AUTH, String(to));
  }
});

test('add-account: only the login token is removed from prompt', () => {
  const base = '/application/o/authorize/?client_id=abc&response_type=code&state=s1';
  assert.equal(flowRedirectTarget('/', q(AUTH + '&prompt=consent'), O), base + '&prompt=consent');
  assert.equal(flowRedirectTarget('/', q(AUTH + '&prompt=select_account'), O), base + '&prompt=select_account');
  assert.equal(flowRedirectTarget('/', q(AUTH + '&prompt=login%20consent'), O), base + '&prompt=consent');
  assert.equal(flowRedirectTarget('/', q(AUTH + '&prompt=consent+login'), O), base + '&prompt=consent');
});

test('malicious next is rejected, challenge.to followed', () => {
  const bad = [
    'https://evil.com/application/o/authorize/',
    '//evil.com/application/o/authorize/',
    '/\\evil.com',
    '/application/o/authorize/\\..\\x',
    '\\\\evil.com/application/o/authorize/',
    'javascript:alert(1)',
    '/application/o/authorize/\n//evil.com',
    '/application/o/token/',
    '/other/application/o/authorize/',
    '/application/o/authorize/../../if/user/',
  ];
  for (const next of bad) assert.equal(flowRedirectTarget('/', q(next), O), '/', next);
});

test('foreign-origin root redirect is not treated as root', () => {
  assert.equal(flowRedirectTarget('https://evil.com/', q(AUTH), O), 'https://evil.com/');
});

test('no next: challenge.to is followed', () => {
  assert.equal(flowRedirectTarget('/', '?flow=x', O), '/');
  assert.equal(flowRedirectTarget('/if/user/', '', O), '/if/user/');
  assert.equal(flowRedirectTarget(undefined, '', O), '/');
});
