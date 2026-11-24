import { useEffect, useRef, useState } from 'react';

/** Decorative only: the adjacent native range owns keyboard/touch/AT interaction. */
export function AudioWaveform({ peaks, progress = 0, live = false }: { peaks: number[]; progress?: number; live?: boolean }) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [barCount, setBarCount] = useState(64);
  const [reducedMotion, setReducedMotion] = useState(false);
  useEffect(() => {
    const query = globalThis.matchMedia?.('(prefers-reduced-motion: reduce)');
    if (!query) return;
    const sync = () => setReducedMotion(query.matches);
    sync();
    query.addEventListener('change', sync);
    return () => query.removeEventListener('change', sync);
  }, []);
  useEffect(() => {
    const container = containerRef.current;
    if (!container || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(([entry]) => {
      if (entry.contentRect.width > 0) setBarCount(Math.max(8, Math.min(64, Math.floor(entry.contentRect.width / 5))));
    });
    observer.observe(container);
    return () => observer.disconnect();
  }, []);
  const history = live ? Array<number>(64 - Math.min(64, peaks.length)).fill(0).concat(peaks.slice(-64)) : peaks;
  // Combine adjacent real peak bins when space is tight; never invent amplitudes.
  const count = Math.min(history.length, barCount);
  const values = Array.from({ length: count }, (_, index) => Math.max(0, ...history.slice(
    Math.floor(index * history.length / count), Math.floor((index + 1) * history.length / count),
  )));
  return <div ref={containerRef} aria-hidden="true" className="pointer-events-none relative flex h-11 w-full min-w-0 items-center gap-[2px] overflow-hidden">
    <svg className="h-11 w-full" viewBox={`0 0 ${values.length * 4} 44`} preserveAspectRatio="none">
      {values.map((value, i) => {
        const height = Math.max(2, (live && reducedMotion ? peaks.at(-1) || 0 : value) * 30);
        const played = live || (i + 0.5) / values.length <= progress;
        return <rect key={i} x={i * 4 + 1} y={(44 - height) / 2} width={2} height={height} rx={1}
          fill={played ? 'var(--color-accent)' : 'var(--color-text-muted)'} opacity={played ? 1 : 0.45} />;
      })}
    </svg>
    {!live && <span className="absolute h-3 w-3 rounded-full bg-accent" style={{ left: `calc(${Math.min(1, Math.max(0, progress)) * 100}% - ${Math.min(1, Math.max(0, progress)) * 12}px)` }} />}
  </div>;
}
