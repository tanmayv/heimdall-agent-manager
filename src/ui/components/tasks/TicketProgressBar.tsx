// The chain progress bar (done / in progress or review / ready / cancelled),
// shared by the ticket board and the owner chain overview.

import React from 'react';
import { progressSegments, type ProgressCounts } from './ticketModel';

const SEGMENT_CLASS: Record<string, string> = {
  done: 'bg-success',
  in_progress: 'bg-info',
  ready: 'bg-faint',
  cancelled: 'bg-strong',
};

const SEGMENT_LABEL: Record<string, string> = {
  done: 'done',
  in_progress: 'in progress or review',
  ready: 'ready or waiting',
  cancelled: 'cancelled',
};

export function TicketProgressBar({ counts, debugId }: { counts: ProgressCounts; debugId: string }) {
  const segments = progressSegments(counts);
  return (
    <div
      role="img"
      aria-label={segments.map((s) => `${s.count} ${SEGMENT_LABEL[s.key]}`).join(', ')}
      data-debug-id={debugId}
      className="flex h-1.5 w-full gap-0.5 overflow-hidden rounded-pill bg-neutral-soft"
    >
      {segments
        .filter((s) => s.count > 0)
        .map((s) => (
          <span key={s.key} className={`h-full ${SEGMENT_CLASS[s.key]}`} style={{ width: `${s.percent}%` }} />
        ))}
    </div>
  );
}
