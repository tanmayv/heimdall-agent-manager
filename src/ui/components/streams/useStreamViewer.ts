import { useEffect, useRef, useState, type RefObject } from 'react';
import { apiAbsoluteUrl } from '../../api/apiBase.ts';
import { createFrameAssembler } from './streamFrames.ts';

import { isContinuousInput, streamInputMessage, type StreamInputEvent } from './streamInput.ts';

export type StreamStatus = 'loading' | 'waiting' | 'live' | 'paused' | 'ended' | 'expired' | 'unavailable' | 'unauthorized' | 'error';
type Metadata = { title: string; expires: number };
const FRAME_IDLE_MS = 10_000;

class StreamRequestError extends Error {
  readonly status: number;
  constructor(status: number) { super('Stream request failed'); this.status = status; }
}

async function fetchStreamJson(path: string, init: RequestInit) {
  const response = await fetch(apiAbsoluteUrl(path), { ...init, credentials: 'include', cache: 'no-store' });
  if (!response.ok) throw new StreamRequestError(response.status);
  return (await response.json()).data;
}

export type ActiveStream = { stream_id: string; title: string };

export async function listOtherStreams(id: string, signal: AbortSignal): Promise<ActiveStream[]> {
  const rows: unknown = await fetchStreamJson('/api/v1/streams', { signal });
  if (!Array.isArray(rows)) throw new Error('Invalid stream list');
  return rows.filter((row): row is ActiveStream => typeof row?.stream_id === 'string' &&
    /^[0-9a-f]{32}$/.test(row.stream_id) && row.stream_id !== id && typeof row.title === 'string');
}

export function streamViewUrl(id: string, ticket: string) {
  const url = new URL(apiAbsoluteUrl(`/api/v1/streams/${encodeURIComponent(id)}/view`));
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.searchParams.set('ticket', ticket);
  return url.toString();
}

export function streamFailure(status: number | undefined, known: Metadata | undefined, now = Date.now()): StreamStatus {
  if (status === 401 || status === 403) return 'unauthorized';
  if (status === 404) {
    if (!known) return 'unavailable'; // The server intentionally hides cross-owner streams.
    return known.expires <= now ? 'expired' : 'ended';
  }
  return 'error';
}

export function useStreamViewer(id: string, beforePause?: RefObject<(() => void) | undefined>) {
  const [status, setStatus] = useState<StreamStatus>('loading');
  const [meta, setMeta] = useState<Metadata>();
  const [image, setImage] = useState<string>();
  const [attempt, setAttempt] = useState(0);

  const liveInput = useRef<((events: StreamInputEvent[]) => void) | undefined>(undefined);

  useEffect(() => {
    const abort = new AbortController();
    const { signal } = abort;
    let socket: WebSocket | undefined;
    let imageUrl: string | undefined;
    let idle: ReturnType<typeof setTimeout> | undefined;
    let expiry: ReturnType<typeof setTimeout> | undefined;
    let connectionDeadline: ReturnType<typeof setTimeout> | undefined;
    let known: Metadata | undefined;
    let finished = false;
    let opened = false;
    let retried = false;
    const path = `/api/v1/streams/${id}`;
    const clearImage = () => {
      if (imageUrl) URL.revokeObjectURL(imageUrl);
      imageUrl = undefined;
    };
    const finish = (next: StreamStatus) => {
      if (finished || signal.aborted) return;
      finished = true;
      liveInput.current = undefined;
      clearTimeout(idle);
      clearTimeout(expiry);
      clearTimeout(connectionDeadline);
      socket?.close();
      clearImage();
      setImage(undefined);
      setStatus(next);
    };
    setStatus('loading');
    setMeta(undefined);
    setImage(undefined);

    if (!/^[0-9a-f]{32}$/.test(id)) {
      setStatus('unavailable');
      return;
    }

    const afterDisconnect = async () => {
      clearTimeout(idle);
      clearTimeout(connectionDeadline);
      if (finished || signal.aborted) return;
      liveInput.current = undefined;
      setStatus('paused');
      try {
        await fetchStreamJson(path, { signal });
        if (!opened) finish('error');
      } catch (error) {
        finish(streamFailure(error instanceof StreamRequestError ? error.status : undefined, known));
      }
    };

    const onIdle = () => {
      if (finished || signal.aborted) return;
      // Flush held input while the old viewer socket is still writable.
      beforePause?.current?.();
      liveInput.current = undefined;
      setStatus('paused');
      if (retried) return;
      retried = true;
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = null;
        socket.close();
      }
      void connect();
    };

    const connect = async () => {
      try {
        opened = false;
        const assembler = createFrameAssembler(id);
        const data = await fetchStreamJson(path, { signal }) as Metadata;
        if (signal.aborted || finished) return;
        if (!data || typeof data.title !== 'string' || !Number.isFinite(data.expires)) {
          finish('error');
          return;
        }
        known = data;
        setMeta(data);
        const remaining = data.expires - Date.now();
        if (remaining <= 0) {
          finish('expired');
          return;
        }
        clearTimeout(expiry);
        expiry = setTimeout(() => finish('expired'), remaining);
        const reply = await fetchStreamJson('/api/v1/me/ws-ticket', {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, signal,
        });
        if (signal.aborted || finished) return;
        if (typeof reply?.ticket !== 'string' || !reply.ticket) {
          finish('error');
          return;
        }
        socket = new WebSocket(streamViewUrl(id, reply.ticket));
        socket.binaryType = 'arraybuffer';
        connectionDeadline = setTimeout(() => socket?.close(), 10_000);
        socket.onopen = () => {
          if (signal.aborted || finished) return;
          opened = true;
          clearTimeout(connectionDeadline);
          setStatus(retried ? 'paused' : 'waiting');
          idle = setTimeout(onIdle, FRAME_IDLE_MS);
        };
        socket.onmessage = ({ data: wire }) => {
          if (signal.aborted || finished || !(wire instanceof ArrayBuffer)) return;
          const frame = assembler(wire);
          if (!frame) return;
          const next = URL.createObjectURL(frame);
          clearImage();
          imageUrl = next;
          setImage(next);
          const peer = socket;
          liveInput.current = events => {
            if (peer?.readyState !== WebSocket.OPEN) return;
            const batch = peer.bufferedAmount < 64 * 1024 ? events : events.filter(event => !isContinuousInput(event));
            if (batch.length) peer.send(streamInputMessage(id, batch));
          };
          setStatus('live');
          clearTimeout(idle);
          idle = setTimeout(onIdle, FRAME_IDLE_MS);
        };
        socket.onclose = () => { void afterDisconnect(); };
      } catch (error) {
        finish(streamFailure(error instanceof StreamRequestError ? error.status : undefined, known));
      }
    };
    void connect();

    return () => {
      abort.abort();
      liveInput.current = undefined;
      clearTimeout(idle);
      clearTimeout(expiry);
      clearTimeout(connectionDeadline);
      if (socket) {
        socket.onopen = socket.onmessage = socket.onclose = null;
        socket.close();
      }
      clearImage();
    };
  }, [id, attempt, beforePause]);

  return { status, meta, image, sendInput: (events: StreamInputEvent[]) => liveInput.current?.(events), reconnect: () => setAttempt(value => value + 1) };
}
