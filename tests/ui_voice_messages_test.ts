// REQ-VOICE-3/4: audio artifacts play inline in chat; the composer records voice messages.
// Covers audio detection, the inline player, the recorder state machine (pure reducer and
// the hook driven by fake getUserMedia/MediaRecorder), the composer mic button and recorder
// panel, the transcript's decrypted-content audio card, and the Electron mic permission policy.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_voice_messages_test.ts

import assert from 'node:assert/strict';
import { after, afterEach, test } from 'node:test';
import fs from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { transformSync } from 'esbuild';
import { configureStore } from '@reduxjs/toolkit';
import { Provider } from 'react-redux';

const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://heimdall.test/', pretendToBeVisual: true });
let blobUrls = 0;
const revoked: string[] = [];
const NodeURL = URL;
class TestURL extends NodeURL {
  static createObjectURL(_blob: Blob) { blobUrls += 1; return `blob:https://heimdall.test/${blobUrls}`; }
  static revokeObjectURL(url: string) { revoked.push(url); }
}
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
  URL: TestURL,
  ResizeObserver: class { observe() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (id: number) => clearTimeout(id),
});
// jsdom has no media playback: record calls and drive state by hand.
const media = dom.window.HTMLMediaElement.prototype as any;
const played: string[] = [];
media.play = function play(this: any) { played.push('play'); this._paused = false; this.dispatchEvent(new dom.window.Event('play')); return Promise.resolve(); };
media.pause = function pause(this: any) { played.push('pause'); this._paused = true; this.dispatchEvent(new dom.window.Event('pause')); };
Object.defineProperty(media, 'paused', { configurable: true, get(this: any) { return this._paused !== false; } });
Object.defineProperty(media, 'duration', { configurable: true, get(this: any) { return this._duration ?? NaN; } });
Object.defineProperty(media, 'currentTime', { configurable: true, get(this: any) { return this._currentTime ?? 0; }, set(this: any, v: number) { this._currentTime = v; } });

const { createRoot } = await import('react-dom/client');
const audio = await import('../src/ui/utils/audioArtifact.ts');
const upload = await import('../src/ui/utils/artifactUpload.ts');
const { normalizeArtifactRecord } = await import('../src/ui/api/endpoints/artifacts.ts');
const { AudioPlayer } = await import('../src/ui/components/chat/AudioPlayer.tsx');
const { useVoiceRecorder } = await import('../src/ui/components/chat/useVoiceRecorder.ts');
const { VoiceRecorderPanel, useVoiceMessage } = await import('../src/ui/components/chat/VoiceRecorderPanel.tsx');
const { MessageComposerActions } = await import('../src/ui/components/chat/MessageComposer.tsx');
const { default: inputPreferences } = await import('../src/ui/store/inputPreferencesSlice.ts');
const { default: vault } = await import('../src/ui/store/vaultSlice.ts');
const { ArtifactAttachmentPreview } = await import('../src/ui/components/ArtifactAttachmentPreview.tsx');
const { artifactContentSession, audioContentStatus } = await import('../src/ui/components/ArtifactAudioPreview.tsx');
after(() => dom.window.close());

const h = React.createElement;
const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });

async function mount(element: React.ReactElement) {
  const store = configureStore({ reducer: { inputPreferences, vault, chat: (s = { session: {} }) => s } as any });
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(h(Provider, { store, children: element })));
  const unmount = async () => { await act(async () => root.unmount()); container.remove(); };
  cleanups.push(unmount);
  return { container, unmount, render: (next: React.ReactElement) => act(async () => root.render(h(Provider, { store, children: next }))) };
}
const q = <T extends Element = HTMLElement>(container: Element, id: string) => container.querySelector<T>(`[data-debug-id="${id}"]`);
const click = (el: Element | null) => act(async () => { (el as HTMLElement).dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });

// --- detection -------------------------------------------------------------------------

test('isAudioArtifact: kind audio/voice, audio/* mime, audio extensions; not video or text', () => {
  const yes = [
    { kind: 'audio' }, { kind: 'Voice' }, { mime: 'audio/webm;codecs=opus' }, { content_type: 'audio/mpeg' },
    { contentType: 'audio/ogg' }, { name: 'reply.mp3' }, { name: 'note.WAV' }, { ext: '.m4a' },
    { name: 'clip.opus', mime: 'application/octet-stream' },
  ];
  const no = [
    null, {}, { kind: 'image', mime: 'image/png' }, { name: 'movie.webm' }, { name: 'movie.mp4' },
    { name: 'notes.ogg', mime: 'text/plain' }, { kind: 'markdown', name: 'a.md' },
  ];
  for (const meta of yes) assert.equal(audio.isAudioArtifact(meta as any), true, JSON.stringify(meta));
  for (const meta of no) assert.equal(audio.isAudioArtifact(meta as any), false, JSON.stringify(meta));
});

test('audioMimeForArtifact types decrypted blobs for <audio>', () => {
  assert.equal(audio.audioMimeForArtifact({ mime: 'audio/webm;codecs=opus' }), 'audio/webm');
  assert.equal(audio.audioMimeForArtifact({ name: 'x.mp3' }), 'audio/mpeg');
  assert.equal(audio.audioMimeForArtifact({ kind: 'voice' }), 'audio/webm');
  assert.equal(audio.audioMimeForArtifact({ kind: 'image', mime: 'image/png' }), '');
});

test('uploads of audio files get kind audio, their mime and a matching extension', () => {
  const file = new File([new Uint8Array([1, 2, 3])], '', { type: 'audio/webm' });
  assert.equal(upload.artifactKindForFile(file), 'audio');
  assert.equal(upload.artifactMimeForFile(file), 'audio/webm');
  assert.match(upload.artifactUploadName(file, 'conversation-attachment'), /^conversation-attachment-.*\.webm$/);
  assert.equal(upload.artifactExtensionForMime('audio/mp4'), '.m4a');
  assert.equal(upload.artifactKindForFile(new File(['x'], 'a.png', { type: 'image/png' })), 'image');
});

test('normalizeArtifactRecord infers kind audio from mime or name and keeps an explicit kind', () => {
  assert.equal(normalizeArtifactRecord({ artifact_id: 'a1', name: 'v.webm', mime: 'audio/webm' }).kind, 'audio');
  assert.equal(normalizeArtifactRecord({ artifact_id: 'a2', name: 'reply.mp3' }).kind, 'audio');
  assert.equal(normalizeArtifactRecord({ artifact_id: 'a3', name: 'reply.mp3', kind: 'voice' }).kind, 'voice');
});

// --- pure helpers -----------------------------------------------------------------------

test('formatAudioTime, resolveAudioDuration and recorder mime selection', () => {
  assert.equal(audio.formatAudioTime(0), '0:00');
  assert.equal(audio.formatAudioTime(63.9), '1:03');
  assert.equal(audio.formatAudioTime(3725), '1:02:05');
  assert.equal(audio.formatAudioTime(NaN), '--:--');
  assert.equal(audio.resolveAudioDuration(12.5, 3000), 12.5);
  assert.equal(audio.resolveAudioDuration(Infinity, 3000), 3);
  assert.ok(Number.isNaN(audio.resolveAudioDuration(Infinity, 0)));
  assert.equal(audio.pickRecorderMimeType((m) => m === 'audio/mp4'), 'audio/mp4');
  assert.equal(audio.pickRecorderMimeType(() => true), 'audio/webm;codecs=opus');
  assert.equal(audio.pickRecorderMimeType(undefined), '');
  assert.match(audio.voiceRecordingName('audio/webm;codecs=opus', new Date('2026-11-21T10:00:00Z')), /^voice-message-2026-11-21T10-00-00-000Z\.webm$/);
});

test('max duration keeps a recording under the 15 MiB artifact cap', () => {
  const bytes = (audio.VOICE_MAX_DURATION_MS / 1000) * (audio.VOICE_BITS_PER_SECOND / 8);
  assert.ok(bytes * 1.5 < audio.VOICE_MAX_BYTES, `${bytes} bytes at the limit`);
});

test('describeMicError explains denied, missing and busy microphones', () => {
  assert.match(audio.describeMicError({ name: 'NotAllowedError' }), /denied/);
  assert.match(audio.describeMicError({ name: 'NotFoundError' }), /No microphone/);
  assert.match(audio.describeMicError({ name: 'NotReadableError' }), /in use/);
  assert.match(audio.describeMicError(new Error('x')), /Recording failed/);
});

test('recorder reducer: idle → requesting → recording → preview → idle, invalid moves ignored', () => {
  const r = audio.voiceRecorderReducer;
  let s = audio.INITIAL_VOICE_RECORDER_STATE;
  assert.equal(r(s, { type: 'stop' } as any), s);
  assert.equal(r(s, { type: 'granted' }), s, 'granted without a request is ignored');
  s = r(s, { type: 'start' });
  assert.equal(s.phase, 'requesting');
  assert.equal(r(s, { type: 'start' }), s, 'a second start is ignored');
  s = r(s, { type: 'granted' });
  assert.equal(s.phase, 'recording');
  s = r(s, { type: 'tick', elapsedMs: 1500 });
  assert.equal(r(s, { type: 'tick', elapsedMs: 900 }).elapsedMs, 1500, 'time never runs backwards');
  s = r(s, { type: 'limit' });
  const recording = { blob: new Blob(['a']), url: 'blob:1', mime: 'audio/webm', durationMs: 1600 };
  s = r(s, { type: 'stopped', recording });
  assert.deepEqual([s.phase, s.elapsedMs, s.limitReached, s.recording], ['preview', 1600, true, recording]);
  assert.equal(r(s, { type: 'cancel' }), s, 'cancel does not drop a preview');
  assert.deepEqual(r(s, { type: 'discard' }), audio.INITIAL_VOICE_RECORDER_STATE);
  assert.deepEqual(r(s, { type: 'sent' }), audio.INITIAL_VOICE_RECORDER_STATE);
});

test('recorder reducer: denied permission and failures land in idle with an error', () => {
  const r = audio.voiceRecorderReducer;
  const requesting = r(audio.INITIAL_VOICE_RECORDER_STATE, { type: 'start' });
  const denied = r(requesting, { type: 'denied', error: 'nope' });
  assert.deepEqual([denied.phase, denied.error], ['idle', 'nope']);
  assert.equal(r(denied, { type: 'dismiss_error' }).error, '');
  assert.equal(r(denied, { type: 'start' }).error, '', 'retrying clears the error');
  const failed = r(r(requesting, { type: 'granted' }), { type: 'failed', error: 'broke' });
  assert.deepEqual([failed.phase, failed.error, failed.recording], ['idle', 'broke', null]);
  assert.equal(r(r(requesting, { type: 'granted' }), { type: 'cancel' }).phase, 'idle');
});

// --- recorder hook with fake browser APIs ------------------------------------------------

function fakeEnv({ deny, mime = 'audio/webm;codecs=opus' }: { deny?: string; mime?: string } = {}) {
  let clock = 1_000;
  const tracks: { stopped: boolean }[] = [];
  const recorders: any[] = [];
  class FakeRecorder {
    static isTypeSupported(m: string) { return m === mime; }
    state = 'inactive';
    mimeType: string;
    options: any;
    ondataavailable: any = null; onstop: any = null; onerror: any = null;
    constructor(_stream: any, options: any) { this.options = options; this.mimeType = options?.mimeType || ''; recorders.push(this); }
    start() { this.state = 'recording'; }
    emit(bytes: number) { this.ondataavailable?.({ data: new Blob([new Uint8Array(bytes)]) }); }
    stop() { if (this.state === 'inactive') return; this.state = 'inactive'; this.emit(100); queueMicrotask(() => this.onstop?.()); }
  }
  const env = {
    now: () => clock,
    MediaRecorder: FakeRecorder as any,
    getUserMedia: async (constraints: any) => {
      assert.ok(constraints.audio && !constraints.video, 'audio only');
      if (deny) throw Object.assign(new Error(deny), { name: deny });
      const track = { stopped: false, stop() { this.stopped = true; } };
      tracks.push(track);
      return { getTracks: () => [track] } as any;
    },
  };
  return { env, tracks, recorders, advance: (ms: number) => { clock += ms; } };
}

let hookValue: any;
function RecorderProbe({ env, maxDurationMs }: { env: any; maxDurationMs?: number }) {
  hookValue = useVoiceRecorder({ env, maxDurationMs });
  return null;
}

test('useVoiceRecorder: record, stop, preview and take an audio File; mic released', async () => {
  const fake = fakeEnv();
  await mount(h(RecorderProbe, { env: fake.env }));
  assert.equal(hookValue.supported, true);
  await act(async () => { await hookValue.start(); });
  assert.equal(hookValue.phase, 'recording');
  assert.equal(fake.recorders[0].options.mimeType, 'audio/webm;codecs=opus');
  assert.equal(fake.recorders[0].options.audioBitsPerSecond, audio.VOICE_BITS_PER_SECOND);
  fake.advance(2_400);
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 300)); });
  assert.ok(hookValue.elapsedMs >= 2_400, `timer ticks (${hookValue.elapsedMs})`);
  await act(async () => { hookValue.stop(); await Promise.resolve(); });
  assert.equal(hookValue.phase, 'preview');
  assert.equal(fake.tracks[0].stopped, true, 'tracks stop with the recording');
  assert.equal(hookValue.recording.mime, 'audio/webm');
  assert.match(hookValue.recording.url, /^blob:/);
  let file: File | null = null;
  await act(async () => { file = hookValue.take(); });
  assert.ok(file);
  assert.equal(file!.type, 'audio/webm');
  assert.match(file!.name, /^voice-message-.*\.webm$/);
  assert.equal(upload.artifactKindForFile(file!), 'audio');
  assert.equal(hookValue.phase, 'idle');
});

test('useVoiceRecorder: permission denied shows an error and never records', async () => {
  const fake = fakeEnv({ deny: 'NotAllowedError' });
  await mount(h(RecorderProbe, { env: fake.env }));
  await act(async () => { await hookValue.start(); });
  assert.equal(hookValue.phase, 'idle');
  assert.match(hookValue.error, /denied/);
  assert.equal(fake.recorders.length, 0);
});

test('useVoiceRecorder: unavailable APIs report it inline', async () => {
  await mount(h(RecorderProbe, { env: { getUserMedia: undefined, MediaRecorder: undefined } }));
  assert.equal(hookValue.supported, false);
  await act(async () => { await hookValue.start(); });
  assert.equal(hookValue.error, audio.MIC_UNAVAILABLE_ERROR);
});

test('useVoiceRecorder: cancel and unmount stop the microphone and keep nothing', async () => {
  const fake = fakeEnv();
  const first = await mount(h(RecorderProbe, { env: fake.env }));
  await act(async () => { await hookValue.start(); });
  await act(async () => { hookValue.cancel(); await Promise.resolve(); });
  assert.equal(hookValue.phase, 'idle');
  assert.equal(hookValue.recording, null);
  assert.equal(fake.tracks[0].stopped, true);
  await act(async () => { await hookValue.start(); });
  assert.equal(hookValue.phase, 'recording');
  await first.unmount();
  assert.equal(fake.tracks[1].stopped, true, 'navigation away releases the mic');
  assert.equal(fake.recorders[1].state, 'inactive');
});

test('useVoiceRecorder: stops by itself at the max duration and at the size guard', async () => {
  const fake = fakeEnv();
  await mount(h(RecorderProbe, { env: fake.env, maxDurationMs: 1_000 }));
  await act(async () => { await hookValue.start(); });
  fake.advance(1_200);
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 300)); });
  assert.equal(hookValue.phase, 'preview');
  assert.equal(hookValue.limitReached, true);
  assert.equal(hookValue.recording.durationMs, 1_000);
  await act(async () => { hookValue.discard(); });
  await act(async () => { await hookValue.start(); });
  await act(async () => { fake.recorders[1].emit(audio.VOICE_MAX_BYTES); await Promise.resolve(); });
  assert.equal(hookValue.phase, 'preview');
  assert.equal(hookValue.limitReached, true);
});

// --- recorder panel + send glue ----------------------------------------------------------

test('voice message: Send uploads an audio attachment, then submits once it is uploaded', async () => {
  const fake = fakeEnv();
  const sent: string[][] = [];
  const uploads: File[] = [];
  let api: any;
  function Composer() {
    const [attachments, setAttachments] = React.useState<any[]>([]);
    const uploadAttachment = (file: File, localId = 'x') => {
      uploads.push(file);
      setAttachments((rows) => [...rows, { localId, id: '', name: file.name, file, status: 'uploading', error: '' }]);
      setTimeout(() => setAttachments((rows) => rows.map((row) => row.localId === localId ? { ...row, id: 'art_voice', status: 'uploaded' } : row)), 5);
    };
    const voice = useVoiceMessage({ attachments, uploadAttachment, env: fake.env as any,
      onReadyToSend: () => sent.push(attachments.filter((a) => a.status === 'uploaded').map((a) => a.id)) });
    api = voice;
    return h(VoiceRecorderPanel, { recorder: voice.recorder, isMobile: false, debugPrefix: 'conversation', onSend: voice.send });
  }
  const { container } = await mount(h(Composer));
  assert.equal(q(container, 'conversation-voice-recorder'), null, 'nothing shows while idle');
  await act(async () => { await api.recorder.start(); });
  assert.equal(q(container, 'conversation-voice-recorder')!.getAttribute('data-phase'), 'recording');
  assert.ok(q(container, 'conversation-voice-timer'));
  await click(q(container, 'conversation-voice-stop'));
  await act(async () => { await Promise.resolve(); });
  assert.ok(q(container, 'conversation-voice-preview-toggle'), 'preview player');
  await click(q(container, 'conversation-voice-send'));
  assert.equal(api.active, true, 'uploading-to-send keeps the composer engaged');
  assert.equal(uploads[0].type, 'audio/webm');
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); });
  assert.deepEqual(sent, [['art_voice']]);
  assert.equal(api.active, false);
});

test('voice message: Discard drops the recording; an error renders inline with Dismiss', async () => {
  const fake = fakeEnv();
  let api: any;
  function Composer() {
    const voice = useVoiceMessage({ attachments: [], uploadAttachment: () => assert.fail('no upload'), onReadyToSend: () => assert.fail('no send'), env: fake.env as any });
    api = voice;
    return h(VoiceRecorderPanel, { recorder: voice.recorder, isMobile: false, debugPrefix: 'bot-chat', onSend: voice.send });
  }
  const { container } = await mount(h(Composer));
  await act(async () => { await api.recorder.start(); });
  await click(q(container, 'bot-chat-voice-stop'));
  await act(async () => { await Promise.resolve(); });
  await click(q(container, 'bot-chat-voice-discard'));
  assert.equal(q(container, 'bot-chat-voice-recorder'), null);
  await act(async () => { api.recorder.dismissError(); });

  const denied = fakeEnv({ deny: 'NotAllowedError' });
  let api2: any;
  function Denied() {
    const voice = useVoiceMessage({ attachments: [], uploadAttachment: () => {}, onReadyToSend: () => {}, env: denied.env as any });
    api2 = voice;
    return h(VoiceRecorderPanel, { recorder: voice.recorder, isMobile: false, debugPrefix: 'bot-chat', onSend: voice.send });
  }
  const second = await mount(h(Denied));
  await act(async () => { await api2.recorder.start(); });
  assert.match(q(second.container, 'bot-chat-voice-error')!.textContent!, /Microphone access was denied/);
  await click(q(second.container, 'bot-chat-voice-error-dismiss'));
  assert.equal(q(second.container, 'bot-chat-voice-recorder'), null);
});

test('composer toolbar: mic button beside attach only when onRecord is given, in both layouts', async () => {
  const base = { debugPrefix: 'conversation', mobile: false, provider: '', model: '', onUpload: () => {}, sendDisabled: true };
  let recorded = 0;
  for (const morph of [undefined, { expanded: true }]) {
    const without = await mount(h(MessageComposerActions, { ...base, morph }));
    assert.equal(q(without.container, 'conversation-mic-btn'), null);
    const withMic = await mount(h(MessageComposerActions, { ...base, morph, onRecord: () => { recorded++; }, recordActive: true }));
    const mic = q<HTMLButtonElement>(withMic.container, 'conversation-mic-btn')!;
    assert.equal(mic.getAttribute('aria-label'), 'Record voice message');
    assert.equal(mic.getAttribute('aria-pressed'), 'true');
    assert.equal(mic.previousElementSibling?.getAttribute('data-debug-id'), 'conversation-attach-btn', 'next to attach');
    await click(mic);
  }
  assert.equal(recorded, 2);
});

// --- player ------------------------------------------------------------------------------

test('AudioPlayer: play/pause, duration (incl. duration-less WebM) and seek', async () => {
  played.length = 0;
  const { container } = await mount(h(AudioPlayer, { src: 'blob:https://heimdall.test/a', debugId: 'p', label: 'Voice message', durationHintMs: 4_000 }));
  const el = q<HTMLAudioElement>(container, 'p-audio')! as any;
  assert.equal(q(container, 'p-time')!.textContent, '0:00 / 0:04', 'recorder hint before metadata');
  // Chromium reports Infinity for MediaRecorder WebM until it scans to the end.
  el._duration = Infinity;
  await act(async () => { el.dispatchEvent(new dom.window.Event('loadedmetadata')); });
  assert.equal(el.currentTime, 1e9, 'probes the real duration');
  el._duration = 65;
  await act(async () => { el.dispatchEvent(new dom.window.Event('durationchange')); });
  assert.equal(el.currentTime, 0, 'probe rewinds');
  assert.equal(q(container, 'p-time')!.textContent, '0:00 / 1:05');
  const toggle = q<HTMLButtonElement>(container, 'p-toggle')!;
  assert.equal(toggle.getAttribute('aria-label'), 'Play voice message');
  await click(toggle);
  assert.deepEqual(played, ['play']);
  assert.equal(q(container, 'p')!.getAttribute('data-playing'), 'true');
  assert.equal(toggle.getAttribute('aria-label'), 'Pause voice message');
  await click(toggle);
  assert.deepEqual(played, ['play', 'pause']);
  const seek = q<HTMLInputElement>(container, 'p-seek')!;
  assert.equal(seek.disabled, false);
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!;
    setter.call(seek, '30');
    seek.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
  });
  assert.equal(el.currentTime, 30);
  assert.equal(q(container, 'p-time')!.textContent, '0:30 / 1:05');
});

test('AudioPlayer without content is disabled and shows an unknown duration', async () => {
  const { container } = await mount(h(AudioPlayer, { src: '', debugId: 'p2' }));
  assert.equal(q<HTMLButtonElement>(container, 'p2-toggle')!.disabled, true);
  assert.equal(q<HTMLInputElement>(container, 'p2-seek')!.disabled, true);
  assert.equal(q(container, 'p2-time')!.textContent, '0:00 / --:--');
});

// --- transcript audio card ---------------------------------------------------------------

test('transcript: an audio artifact renders the inline player from fetched (decrypt-aware) content', async () => {
  const requests: string[] = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (url: string) => {
    requests.push(String(url));
    if (String(url).endsWith('/content')) return new Response(new Blob([new Uint8Array([26, 69, 223, 163])]), { status: 200 });
    return new Response(JSON.stringify({ artifact: { artifact_id: 'art_v', name: 'voice-message.webm', kind: 'audio', mime: 'audio/webm' } }), { status: 200 });
  }) as any;
  try {
    const { container } = await mount(h(ArtifactAttachmentPreview, { artifactId: 'art_v', session: { daemonUrl: '', clientToken: '' }, debugId: 't' }));
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); });
    assert.ok(q(container, 't-audio-card'), 'audio card, not an image or a link chip');
    assert.deepEqual(requests, ['/api/v1/artifacts/art_v', '/api/v1/artifacts/art_v/content']);
    assert.match(q<HTMLAudioElement>(container, 't-audio-player-audio')!.getAttribute('src') || '', /^blob:/);
    assert.equal(q<HTMLButtonElement>(container, 't-audio-player-toggle')!.disabled, false);
    assert.equal(q(container, 't-link')!.getAttribute('href'), '#/library/artifacts/art_v');
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('audio content session and status helpers', () => {
  assert.deepEqual(artifactContentSession({ daemonUrl: '', clientToken: '' }, { daemonUrl: 'https://hub', clientToken: 'tok' }), { daemonUrl: '', clientToken: 'v1' });
  assert.deepEqual(artifactContentSession(undefined, { daemonUrl: 'https://hub', clientToken: 'tok' }), { daemonUrl: 'https://hub', clientToken: 'tok' });
  const base = { loading: false, error: '', locked: false, lockReason: '' as const, blob: null };
  assert.match(audioContentStatus({ ...base, locked: true, lockReason: 'locked' }), /Unlock the vault/);
  assert.match(audioContentStatus({ ...base, locked: true, lockReason: 'other_vault' }), /previous vault/);
  assert.equal(audioContentStatus({ ...base, error: 'x' }), 'Audio unavailable.');
  assert.equal(audioContentStatus({ ...base, loading: true }), 'Loading audio…');
  assert.equal(audioContentStatus({ ...base, blob: new Blob(['a']) }), '');
});

// --- Electron microphone permissions -----------------------------------------------------

function loadCts(name: string) {
  const source = fs.readFileSync(new URL(`../src/ui/electron/${name}.cts`, import.meta.url), 'utf8');
  const module = { exports: {} as any };
  vm.runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs' }).code,
    { module, exports: module.exports, URL: NodeURL, console: { warn() {} }, process: { platform: 'linux' }, Promise });
  return module.exports;
}

test('electron: microphone is granted to the app origin main frame only, camera never', async () => {
  const perms = loadCts('mediaPermissions');
  const trusted = ['https://web.ninjy.ai'];
  const req = (details: any) => perms.mediaRequestAllowed('media', details, trusted);
  assert.equal(req({ mediaTypes: ['audio'], requestingUrl: 'https://web.ninjy.ai/#/chat', isMainFrame: true }), true);
  assert.equal(req({ mediaTypes: ['audio'], requestingUrl: 'https://evil.example/', isMainFrame: true }), false);
  assert.equal(req({ mediaTypes: ['audio'], requestingUrl: 'https://web.ninjy.ai/', isMainFrame: false }), false);
  assert.equal(req({ mediaTypes: ['video'], requestingUrl: 'https://web.ninjy.ai/' }), false);
  assert.equal(req({ mediaTypes: ['audio', 'video'], requestingUrl: 'https://web.ninjy.ai/' }), false);
  assert.equal(req({ mediaTypes: [], requestingUrl: 'https://web.ninjy.ai/' }), false);
  assert.equal(perms.mediaRequestAllowed('notifications', {}, trusted), null, 'other permissions keep the default');
  assert.equal(perms.mediaCheckAllowed('media', 'https://web.ninjy.ai', { mediaType: 'audio' }, trusted), true);
  assert.equal(perms.mediaCheckAllowed('media', 'https://web.ninjy.ai', { mediaType: 'video' }, trusted), false);
  assert.equal(perms.mediaCheckAllowed('media', 'https://evil.example', { mediaType: 'audio' }, trusted), false);

  let requestHandler: any; let checkHandler: any;
  const session = { setPermissionRequestHandler: (fn: any) => { requestHandler = fn; }, setPermissionCheckHandler: (fn: any) => { checkHandler = fn; } };
  const asked: string[] = [];
  perms.installMediaPermissions({ session, trustedOrigins: () => trusted, platform: 'darwin',
    systemPreferences: { getMediaAccessStatus: () => 'not-determined', askForMediaAccess: async (m: string) => { asked.push(m); return true; } } });
  const decide = (permission: string, details: any) => new Promise<boolean>((resolve) => requestHandler({}, permission, resolve, details));
  assert.equal(await decide('media', { mediaTypes: ['audio'], requestingUrl: 'https://web.ninjy.ai/', isMainFrame: true }), true);
  assert.deepEqual(asked, ['microphone'], 'macOS system prompt is asked first');
  assert.equal(await decide('media', { mediaTypes: ['video'], requestingUrl: 'https://web.ninjy.ai/' }), false);
  assert.equal(await decide('clipboard-sanitized-write', {}), true);
  assert.equal(checkHandler({}, 'media', 'https://evil.example', { mediaType: 'audio' }), false);
  assert.equal(checkHandler({}, 'notifications', 'https://web.ninjy.ai', {}), true);

  perms.installMediaPermissions({ session, trustedOrigins: () => trusted, platform: 'darwin',
    systemPreferences: { getMediaAccessStatus: () => 'denied' } });
  assert.equal(await decide('media', { mediaTypes: ['audio'], requestingUrl: 'https://web.ninjy.ai/', isMainFrame: true }), false, 'denied in System Settings');
});

test('macOS packaging declares the microphone entitlement and usage description', () => {
  const plist = fs.readFileSync(new URL('../build/entitlements.mac.plist', import.meta.url), 'utf8');
  assert.match(plist, /<key>com\.apple\.security\.device\.audio-input<\/key>\s*<true\/>/);
  const builder = fs.readFileSync(new URL('../electron-builder.yml', import.meta.url), 'utf8');
  assert.match(builder, /extendInfo:\s*\n(?:\s*#.*\n)*\s*NSMicrophoneUsageDescription: \S/);
});
