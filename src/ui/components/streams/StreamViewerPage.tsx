import { Alert, Button, EmptyState, PageShell, Panel, Spinner, StatusPill, Text } from '@ui';
import { useStreamViewer, type StreamStatus } from './useStreamViewer.ts';

const copy = {
  loading: ['Connecting', 'Checking access to this shared tab.'],
  waiting: ['Waiting', 'Connected. The first image will appear here.'],
  live: ['Live', 'You’re seeing the latest image from the shared tab.'],
  paused: ['Paused', 'No new images are arriving. Reconnect to check the stream.'],
  ended: ['Ended', 'The shared tab is no longer streaming. Ask the sender for a new link.'],
  expired: ['Expired', 'This stream reached its time limit. Ask the sender for a new link.'],
  unavailable: ['Unavailable', 'This link may have expired or may belong to another account.'],
  unauthorized: ['Access required', 'Sign in with the account this stream was shared with, then reconnect.'],
  error: ['Connection error', 'The stream could not be reached. Check your connection and try again.'],
} as const satisfies Record<StreamStatus, readonly [string, string]>;

export default function StreamViewerPage({ streamId }: { streamId: string }) {
  const { status, image, meta, reconnect } = useStreamViewer(streamId);
  const [label, description] = copy[status];
  const retry = status === 'paused' || status === 'error' || status === 'unauthorized' || status === 'unavailable';
  const failure = status === 'error' || status === 'unauthorized';
  const emptyTitle = { waiting: 'Waiting for the first image', paused: 'No image available',
    ended: 'The stream has ended', expired: 'The link has expired', unavailable: 'Stream not found' };
  const tone = status === 'live' ? 'success' : failure ? 'danger' : status === 'paused' ? 'warning' :
    status === 'loading' || status === 'waiting' ? 'pending' : 'neutral';

  return (
    <PageShell
      title={<span className="break-words">{meta?.title || 'Shared tab'}</span>}
      eyebrow="Tab stream"
      description="Watch only. You can’t interact with the shared tab."
      width="wide"
      rhythm="banded"
      actions={retry && <Button variant="primary" onClick={reconnect}>Reconnect</Button>}
    >
      <Panel tone="sunken" padding="none" className="overflow-hidden">
        <div className="flex flex-wrap items-center gap-3 border-b border-subtle p-4" role="status" aria-live="polite">
          <StatusPill tone={tone}>{label}</StatusPill>
          {status === 'loading' && <Spinner size="sm" label="Checking access" />}
          {(image || status === 'loading') && (
            <Text role="body-sm" tone="muted">{status === 'paused' ? 'Showing the last received image.' : description}</Text>
          )}
        </div>
        {image ? (
          <img className="block h-auto w-full" src={image} alt="Latest image of the shared tab" />
        ) : failure ? (
          <div className="p-4"><Alert tone="danger">{description}</Alert></div>
        ) : status === 'loading' ? null : (
          <div className="p-4"><EmptyState title={emptyTitle[status as keyof typeof emptyTitle] || label} description={description} /></div>
        )}
      </Panel>
    </PageShell>
  );
}
