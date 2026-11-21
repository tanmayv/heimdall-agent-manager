import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { AudioWaveform } from './AudioWaveform';
import { decodeWaveform, onWaveformSlot, waveformAdmitted } from '../../utils/audioWaveform';
import { Icon } from '@ui';
import { formatAudioTime, resolveAudioDuration } from '../../utils/audioArtifact';

/** Far past any real duration: seeking here makes Chromium scan a duration-less WebM to the end. */
const DURATION_PROBE_SECONDS = 1e9;

/**
 * REQ-VOICE-3: the inline audio player (play/pause, seek, elapsed / duration) used in chat
 * transcripts, the artifact viewer and the composer's recording preview. `src` is a blob: URL
 * of already-decrypted content; analysis reads only that local decrypted blob URL.
 */
export function AudioPlayer({ src, debugId, label = 'Audio', durationHintMs = 0, className = '' }: {
  src: string;
  debugId: string;
  /** Accessible name prefix for the controls ("Play voice message"). */
  label?: string;
  /** A known length (the recorder's measurement) for files whose header has none. */
  durationHintMs?: number;
  className?: string;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [waveform, setWaveform] = useState<{ src: string; peaks: number[] } | null>(null);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const probing = useRef(false);
  const [playing, setPlaying] = useState(false);
  const [current, setCurrent] = useState(0);
  const [rawDuration, setRawDuration] = useState(NaN);
  const [error, setError] = useState('');
  const duration = resolveAudioDuration(rawDuration, durationHintMs);
  const seekable = Number.isFinite(duration) && duration > 0;

  useEffect(() => {
    setWaveform(null);
    setPlaying(false);
    setCurrent(0);
    setRawDuration(NaN);
    setError('');
    probing.current = false;
  }, [src]);

  useEffect(() => {
    if (!waveformAdmitted(duration) || !src.startsWith('blob:')) return;
    const abort = new AbortController();
    let visible = typeof IntersectionObserver === 'undefined';
    let attempted = false;
    const analyse = async () => {
      if (!visible || attempted || abort.signal.aborted) return;
      attempted = true;
      const result = await decodeWaveform(src, duration, abort.signal);
      if (abort.signal.aborted) return;
      if (result === 'busy') { attempted = false; return; }
      if (result) setWaveform({ src, peaks: result });
    };
    const unsubscribe = onWaveformSlot(() => { void analyse(); });
    const observer = typeof IntersectionObserver !== 'undefined' ? new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      if (visible) void analyse();
    }) : null;
    if (containerRef.current) observer?.observe(containerRef.current);
    void analyse();
    return () => { abort.abort(); observer?.disconnect(); unsubscribe(); };
  }, [src, duration]);
  const peaks = waveform?.src === src ? waveform.peaks : null;

  // Pause when the player leaves the page (message list virtualisation, closing a viewer).
  useEffect(() => () => { audioRef.current?.pause(); }, []);

  function syncDuration(audio: HTMLAudioElement) {
    const value = audio.duration;
    if (value === Infinity && !probing.current) {
      probing.current = true;
      try { audio.currentTime = DURATION_PROBE_SECONDS; } catch { probing.current = false; }
      return;
    }
    if (Number.isFinite(value) && value > 0) {
      setRawDuration(value);
      if (probing.current) {
        probing.current = false;
        try { audio.currentTime = 0; } catch {}
        setCurrent(0);
      }
    }
  }

  async function toggle() {
    const audio = audioRef.current;
    if (!audio || !src) return;
    if (!audio.paused) { audio.pause(); return; }
    setError('');
    try {
      if (seekable && audio.currentTime >= duration - 0.05) audio.currentTime = 0;
      await audio.play();
    } catch (err: any) {
      if (err?.name !== 'AbortError') setError('This audio could not be played.');
    }
  }

  function seek(value: number) {
    const audio = audioRef.current;
    if (!audio || !seekable) return;
    const next = Math.min(Math.max(0, value), duration);
    try { audio.currentTime = next; } catch {}
    setCurrent(next);
  }

  return (
    <div ref={containerRef} data-debug-id={debugId} data-playing={playing ? 'true' : 'false'}
      className={`flex min-w-0 flex-wrap items-center gap-2 ${className}`}>
      <audio
        ref={audioRef}
        data-debug-id={`${debugId}-audio`}
        src={src || undefined}
        preload="metadata"
        onLoadedMetadata={(event) => syncDuration(event.currentTarget)}
        onDurationChange={(event) => syncDuration(event.currentTarget)}
        onTimeUpdate={(event) => { if (!probing.current) setCurrent(event.currentTarget.currentTime); }}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onEnded={() => setPlaying(false)}
        onError={() => { if (src) setError('This audio could not be played.'); setPlaying(false); }}
        className="hidden"
      />
      <button
        type="button"
        data-debug-id={`${debugId}-toggle`}
        aria-label={playing ? `Pause ${label.toLowerCase()}` : `Play ${label.toLowerCase()}`}
        disabled={!src}
        onClick={() => void toggle()}
        className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-neutral-soft text-primary hover:bg-strong disabled:opacity-45"
      >
        <Icon name={playing ? 'pause' : 'play'} size="sm" />
      </button>
      <div className="min-w-0 flex-1">
        <div className="relative min-w-0 rounded-md focus-within:ring-2 focus-within:ring-[var(--color-accent)]">
          {peaks ? <AudioWaveform peaks={peaks} progress={seekable ? current / duration : 0} /> : null}
          <input
            type="range"
            data-debug-id={`${debugId}-seek`}
            aria-label={`Seek ${label.toLowerCase()}`}
            aria-valuetext={`${formatAudioTime(current)} of ${formatAudioTime(duration)}`}
            min={0}
            max={seekable ? duration : 0}
            step="any"
            value={seekable ? Math.min(current, duration) : 0}
            disabled={!seekable}
            onChange={(event) => seek(Number(event.currentTarget.value))}
            style={{ accentColor: 'var(--color-accent)' } as CSSProperties}
            className={peaks ? 'absolute inset-0 h-11 w-full cursor-pointer opacity-0 disabled:cursor-default' : 'h-11 w-full min-w-0 cursor-pointer disabled:cursor-default disabled:opacity-45'}
          />
        </div>
        <span data-debug-id={`${debugId}-time`} className="shrink-0 font-mono text-caption tabular-nums text-muted">
          {formatAudioTime(current)} / {formatAudioTime(duration)}
        </span>
      </div>
      {error ? <span role="alert" data-debug-id={`${debugId}-error`} className="w-full text-caption text-danger">{error}</span> : null}
    </div>
  );
}
