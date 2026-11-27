export type FitMode = 'fit-width' | 'fit-height';
export type Size = { width: number; height: number };
export type Pan = { x: number; y: number };

export const centeredPan: Pan = { x: 0, y: 0 };

export function toggleFit(mode: FitMode): { mode: FitMode; pan: Pan } {
  return { mode: mode === 'fit-width' ? 'fit-height' : 'fit-width', pan: centeredPan };
}

export function fitFrame(mode: FitMode, frame: Size, viewport: Size): Size {
  return mode === 'fit-width'
    ? { width: viewport.width, height: frame.height * viewport.width / frame.width }
    : { width: frame.width * viewport.height / frame.height, height: viewport.height };
}

export function clampPan(pan: Pan, frame: Size, viewport: Size): Pan {
  const x = Math.max(0, (frame.width - viewport.width) / 2);
  const y = Math.max(0, (frame.height - viewport.height) / 2);
  return { x: x ? Math.min(x, Math.max(-x, pan.x)) : 0, y: y ? Math.min(y, Math.max(-y, pan.y)) : 0 };
}
