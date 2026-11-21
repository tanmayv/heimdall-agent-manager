/** Browser evidence fixture: real Web Audio oscillator stream, native MediaRecorder/decoder.
 * No physical microphone, Hub, decryption or upload is exercised by this isolated fixture.
 */
import React, { useEffect } from 'react';
import { createRoot } from 'react-dom/client';
import { VoiceRecorderPanel } from '../../src/ui/components/chat/VoiceRecorderPanel';
import { useVoiceRecorder } from '../../src/ui/components/chat/useVoiceRecorder';
import { AudioPlayer } from '../../src/ui/components/chat/AudioPlayer';

const metrics: Record<string, any> = {};
Object.assign(window, { voiceMetrics: metrics });
const contexts: AudioContext[] = [];
const gains: GainNode[] = [];
const env = {
  MediaRecorder,
  getUserMedia: async () => {
    metrics.requests = (metrics.requests || 0) + 1;
    const context = new AudioContext();
    contexts.push(context);
    const oscillator = context.createOscillator();
    const gain = context.createGain();
    gain.gain.value = 0.1;
    gains.push(gain);
    const output = context.createMediaStreamDestination();
    oscillator.connect(gain).connect(output);
    oscillator.start();
    await context.resume();
    return output.stream;
  },
};
function Composer({ prefix, title }: { prefix: string; title: string }) {
  const recorder = useVoiceRecorder({ env });
  useEffect(() => { metrics[prefix] = { phase: recorder.phase, amplitudes: recorder.amplitudes }; }, [recorder.phase, recorder.amplitudes]);
  return <section style={{ margin: '24px 0' }}>
    <h2 style={{ marginBottom: 12, fontSize: 18 }}>{title}</h2>
    <VoiceRecorderPanel recorder={recorder} isMobile debugPrefix={prefix} onSend={() => { metrics.sends = (metrics.sends || 0) + 1; }} />
    <button data-debug-id={`${prefix}-record`} onClick={() => void recorder.start()}>Record test tone</button>
  </section>;
}
// Known WAV PCM with changing amplitude; playback peaks must be computed by decodeAudioData.
const rate = 16000;
const samples = rate * 4;
const data = new ArrayBuffer(44 + samples * 2);
const view = new DataView(data);
const text = (offset: number, value: string) => Array.from(value).forEach((char, i) => view.setUint8(offset + i, char.charCodeAt(0)));
text(0, 'RIFF'); view.setUint32(4, data.byteLength - 8, true); text(8, 'WAVE'); text(12, 'fmt ');
view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true); view.setUint32(24, rate, true);
view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true); text(36, 'data'); view.setUint32(40, samples * 2, true);
for (let i = 0; i < samples; i++) {
  const envelope = i < rate / 2 ? 0 : 0.1 + 0.75 * Math.pow(Math.sin(i / rate * 4), 2);
  view.setInt16(44 + i * 2, Math.sin(i / rate * Math.PI * 2 * 220) * envelope * 32767, true);
}
const src = URL.createObjectURL(new Blob([data], { type: 'audio/wav' }));
Object.assign(window, { setToneLevel: (level: number) => gains.forEach((gain) => { gain.gain.value = level; }),
  closeToneContexts: () => Promise.all(contexts.map((context) => context.close())) });
createRoot(document.getElementById('root')!).render(<main style={{ maxWidth: 640, padding: 16, margin: 'auto' }}>
  <h1 style={{ fontSize: 22 }}>Voice waveform regression fixture</h1>
  <p style={{ color: 'var(--color-text-muted)', marginTop: 8 }}>Measured test tone · shared production chat components</p>
  <Composer prefix="conversation" title="Agent composer" />
  <Composer prefix="bot-chat" title="Bot composer" />
  <section style={{ marginTop: 24 }}><h2>Decoded WAV playback</h2><AudioPlayer src={src} debugId="fixture-playback" label="Voice message" /></section>
</main>);
