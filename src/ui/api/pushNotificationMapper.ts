// Pure mapping layer for Web Push payloads (Level 2).
//
// The Hub encrypts a small JSON payload and the service worker reads it via
// `event.data.json()`. This module turns that raw payload into a concrete
// `NotificationPlan` describing exactly what the service worker should show —
// with NO DOM/permission/side effects — so the decision is unit-testable by
// feeding raw payloads (see tests/ui_push_notification_mapper_test.ts).
//
// Unlike the in-page WS mapper (`notificationMapper.ts`), this mapper is total:
// on iOS a `push` that does NOT result in a visible notification causes Safari
// to revoke the push permission, so we must ALWAYS produce something to show
// even when the payload is empty or malformed. The side-effectful rendering
// (calling `registration.showNotification`) lives in the service worker.

import type { NotificationCategory } from './notificationMapper';

// The wire payload the Hub sends (see the design doc WIRE CONTRACT). Every field
// is optional on the wire; the mapper fills sensible fallbacks so we always show
// a notification. `href` is an absolute deep-link the SW opens on click.
export type PushPayload = {
  title?: unknown;
  body?: unknown;
  tag?: unknown;
  route?: unknown;
  category?: unknown;
  href?: unknown;
};

// What the service worker actually renders. Mirrors the click-handoff contract
// used by the existing notificationclick handler (`data: { route, href }`).
export type PushNotificationPlan = {
  title: string;
  body: string;
  tag: string;
  route: string;
  href: string;
  category: NotificationCategory;
};

// Shown when the payload is missing/undecodable so iOS still sees a visible
// notification (otherwise it revokes the push permission).
const FALLBACK_TITLE = 'Heimdall';
const FALLBACK_BODY = 'You have a new notification.';
const FALLBACK_TAG = 'heimdall:push';
const FALLBACK_ROUTE = '/conversations';

function str(value: unknown): string {
  return value === undefined || value === null ? '' : String(value);
}

function truncate(text: string, max = 140): string {
  const trimmed = text.replace(/\s+/g, ' ').trim();
  if (trimmed.length <= max) return trimmed;
  return `${trimmed.slice(0, max - 1)}…`;
}

// Only the two curated buckets are valid; anything else falls back to
// 'attention' so per-category behaviour stays predictable.
function normalizeCategory(value: unknown): NotificationCategory {
  return str(value) === 'chat' ? 'chat' : 'attention';
}

// Map a decoded push payload to a concrete, always-showable plan. Total by
// design: a null/empty/garbage payload yields the Heimdall fallback so the
// service worker can still call showNotification (iOS permission requirement).
export function planForPushPayload(payload: PushPayload | null | undefined): PushNotificationPlan {
  const p = payload && typeof payload === 'object' ? payload : {};
  const title = truncate(str(p.title)) || FALLBACK_TITLE;
  const body = truncate(str(p.body)) || FALLBACK_BODY;
  const tag = str(p.tag) || FALLBACK_TAG;
  const route = str(p.route) || FALLBACK_ROUTE;
  const href = str(p.href);
  return {
    title,
    body,
    tag,
    route,
    href,
    category: normalizeCategory(p.category),
  };
}
