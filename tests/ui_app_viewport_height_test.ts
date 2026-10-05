import test from 'node:test';
import assert from 'node:assert/strict';
import {
  APP_VIEWPORT_HEIGHT_VAR,
  APP_VIEWPORT_POLL_MS,
  APP_VIEWPORT_SETTLE_DELAYS_MS,
  appViewportHeightFrom,
  installAppViewportHeightSync,
  readAppViewportHeight,
  type AppViewportReading,
  type AppViewportWindow,
} from '../src/ui/utils/appViewportHeight.ts';

// ---------------------------------------------------------------------------
// REQ-KBD-2 — the app shell's height must track the VISUAL viewport.
//
// Verification criteria V-1..V-4 (cmt_18db98317d7934b6) applied deliberately:
//
// V-1  Every assertion below calls the PRODUCTION symbols imported above. There is
//      no inline re-implementation of the arithmetic, and no `assert.match` over
//      `.tsx`/`.css` source text as the sole evidence for a behaviour.
//
// V-2  The fixtures mirror the surface REQ-KBD-1 MEASURED, which is `resizes-visual`:
//      `innerHeight` CONSTANT at 812 while `visualHeight` falls 812 -> 409, with
//      `visualOffsetTop` non-zero and varying. NOTE: V-2 as originally written
//      mandated the opposite (`innerHeight` shrinking together with `visualHeight`,
//      premised on `interactive-widget=resizes-content`). REQ-KBD-1 REFUTED that on
//      device — H1: `innerHeight` stayed 812 throughout; WebKit does not implement
//      `interactive-widget`. Holding `innerHeight` constant is therefore the fixture
//      that matches reality, and it is the REQ-KBD-2 brief's corrected wording.
//
// V-3  No mechanism is deleted here (that is REQ-KBD-3), so no tests are deleted.
//
// V-4  A headless runtime has no software keyboard. These tests establish that the
//      production arithmetic and the sampling strategy are correct for the readings
//      measured on device; they CANNOT establish "the composer is visible above a
//      real keyboard". That remains a device-only acceptance condition.
// ---------------------------------------------------------------------------

/** The device-measured keyboard-raised steady state (REQ-KBD-1 §1). */
const DEVICE_LAYOUT_HEIGHT = 812;
const DEVICE_VISUAL_HEIGHT_KEYBOARD_UP = 409;

const reading = (over: Partial<AppViewportReading> = {}): AppViewportReading => ({
  innerHeight: DEVICE_LAYOUT_HEIGHT,
  visualHeight: DEVICE_LAYOUT_HEIGHT,
  scale: 1,
  ...over,
});

test('appViewportHeightFrom returns the visual viewport height, not the layout height', () => {
  // The measured steady state: layout 812, visual 409. The shell must be 409 tall so
  // its bottom edge lands where the keyboard starts instead of 403px behind it.
  assert.equal(
    appViewportHeightFrom(reading({ visualHeight: DEVICE_VISUAL_HEIGHT_KEYBOARD_UP })),
    DEVICE_VISUAL_HEIGHT_KEYBOARD_UP,
  );
  // Keyboard dismissed: the two agree, so nothing changes.
  assert.equal(appViewportHeightFrom(reading()), DEVICE_LAYOUT_HEIGHT);
});

test('appViewportHeightFrom ignores visualOffsetTop entirely — it is not even an input', () => {
  // The mechanism this replaces computed `innerHeight - visualHeight - visualOffsetTop`.
  // Across 350 focused device samples `visualOffsetTop` ranged -111..+466 for ONE
  // physically constant 403px keyboard, and that formula produced 40 distinct values
  // (REQ-KBD-1 §5, H5). A height derived from a continuously-panning offset is
  // non-deterministic by construction, so the production reading type has no field for
  // it: the type below would not compile with one.
  assert.ok(!('visualOffsetTop' in reading()));
  for (const visualOffsetTop of [0, 403, -111, 466, 41, 99, 105, 127, 221, 456]) {
    // Passed as an excess property through a widened type: whatever the pan is doing,
    // the answer for one physically constant keyboard must be the one constant 409.
    const withPan = { ...reading({ visualHeight: DEVICE_VISUAL_HEIGHT_KEYBOARD_UP }), visualOffsetTop };
    assert.equal(
      appViewportHeightFrom(withPan),
      DEVICE_VISUAL_HEIGHT_KEYBOARD_UP,
      `visualOffsetTop=${visualOffsetTop} must not change the height`,
    );
  }
});

test('appViewportHeightFrom falls back to the layout height without visualViewport', () => {
  // Desktop Safari/Firefox paths and any surface where `visualViewport` is absent.
  assert.equal(appViewportHeightFrom(reading({ visualHeight: null, scale: null })), DEVICE_LAYOUT_HEIGHT);
  // Garbage readings must not collapse the shell to 0 and black out the app.
  assert.equal(appViewportHeightFrom(reading({ visualHeight: 0 })), DEVICE_LAYOUT_HEIGHT);
  assert.equal(appViewportHeightFrom(reading({ visualHeight: -5 })), DEVICE_LAYOUT_HEIGHT);
  assert.equal(appViewportHeightFrom(reading({ visualHeight: Number.NaN })), DEVICE_LAYOUT_HEIGHT);
});

test('appViewportHeightFrom does not shrink the shell for pinch-zoom', () => {
  // Pinch-zooming in also shrinks `visualViewport.height`, but that is a magnifier,
  // not a keyboard. Shrinking the shell there would reflow the app mid-zoom.
  assert.equal(appViewportHeightFrom(reading({ visualHeight: 300, scale: 2.5 })), DEVICE_LAYOUT_HEIGHT);
  // A scale of exactly 1 (and the sub-threshold jitter around it) is NOT pinch-zoom.
  assert.equal(appViewportHeightFrom(reading({ visualHeight: 409, scale: 1 })), 409);
  assert.equal(appViewportHeightFrom(reading({ visualHeight: 409, scale: 1.005 })), 409);
});

test('appViewportHeightFrom rounds to whole pixels', () => {
  // iOS reports fractional visual heights; a fractional CSS px height produces
  // sub-pixel seams at the composer's bottom edge.
  assert.equal(appViewportHeightFrom(reading({ visualHeight: 408.6666 })), 409);
});

// --- the sampling strategy, which is the half that was actually broken before -----

type Listener = () => void;

/** A fake window with controllable timers — no DOM, no jsdom. */
function makeWindow(initial: { innerHeight: number; visualHeight: number | null; scale?: number }) {
  const winListeners = new Map<string, Set<Listener>>();
  const vvListeners = new Map<string, Set<Listener>>();
  const add = (m: Map<string, Set<Listener>>) => (type: string, fn: Listener) => {
    if (!m.has(type)) m.set(type, new Set());
    m.get(type)!.add(fn);
  };
  const remove = (m: Map<string, Set<Listener>>) => (type: string, fn: Listener) => {
    m.get(type)?.delete(fn);
  };

  const writes: string[] = [];
  let now = 0;
  let nextHandle = 1;
  const timeouts = new Map<number, { at: number; fn: Listener }>();
  const intervals = new Map<number, { every: number; next: number; fn: Listener }>();

  const vv = initial.visualHeight === null
    ? null
    : {
        height: initial.visualHeight,
        scale: initial.scale ?? 1,
        addEventListener: add(vvListeners),
        removeEventListener: remove(vvListeners),
      };

  const win = {
    innerHeight: initial.innerHeight,
    visualViewport: vv,
    document: {
      documentElement: {
        style: {
          setProperty: (name: string, value: string) => writes.push(`${name}=${value}`),
        },
      },
    },
    addEventListener: add(winListeners),
    removeEventListener: remove(winListeners),
    setTimeout: (fn: Listener, ms: number) => {
      const h = nextHandle++;
      timeouts.set(h, { at: now + ms, fn });
      return h;
    },
    clearTimeout: (h: never) => void timeouts.delete(h as unknown as number),
    setInterval: (fn: Listener, every: number) => {
      const h = nextHandle++;
      intervals.set(h, { every, next: now + every, fn });
      return h;
    },
    clearInterval: (h: never) => void intervals.delete(h as unknown as number),
  } satisfies AppViewportWindow;

  /** Advance fake time, firing timeouts and intervals in chronological order. */
  const advance = (ms: number) => {
    const target = now + ms;
    for (;;) {
      let soonest = Number.POSITIVE_INFINITY;
      let fire: Listener | null = null;
      let handle = -1;
      for (const [h, t] of timeouts) if (t.at < soonest) { soonest = t.at; fire = t.fn; handle = h; }
      for (const [, i] of intervals) if (i.next < soonest) { soonest = i.next; fire = i.fn; handle = -1; }
      if (fire === null || soonest > target) break;
      now = soonest;
      if (handle >= 0) timeouts.delete(handle);
      for (const [, i] of intervals) if (i.next <= now) i.next = now + i.every;
      fire();
    }
    now = target;
  };

  const emit = (which: 'win' | 'vv', type: string) => {
    const m = which === 'win' ? winListeners : vvListeners;
    for (const fn of [...(m.get(type) ?? [])]) fn();
  };

  const listenerCount = () => {
    let n = 0;
    for (const s of winListeners.values()) n += s.size;
    for (const s of vvListeners.values()) n += s.size;
    return n;
  };

  return { win, writes, advance, emit, listenerCount, vv, timerCount: () => timeouts.size + intervals.size };
}

test('installAppViewportHeightSync publishes the height immediately on install', () => {
  const h = makeWindow({ innerHeight: 812, visualHeight: 812 });
  const stop = installAppViewportHeightSync(h.win);
  assert.deepEqual(h.writes, [`${APP_VIEWPORT_HEIGHT_VAR}=812px`]);
  stop();
});

test('installAppViewportHeightSync picks up the SETTLED state when no event ever fires', () => {
  // THIS IS THE DEFECT THAT MADE THE OLD HOOK USELESS. On device the settled
  // keyboard-up state (`innerH 812, vvH 409`) held for SIX SECONDS and fired NO
  // viewport event at all; `window.resize` never fired once in the whole session
  // (REQ-KBD-1 §3). An event-only listener can never see it. The standing poll must.
  const h = makeWindow({ innerHeight: 812, visualHeight: 812 });
  const stop = installAppViewportHeightSync(h.win);
  h.writes.length = 0;

  // The keyboard rises. Nothing notifies us — deliberately: emit no event.
  h.vv!.height = DEVICE_VISUAL_HEIGHT_KEYBOARD_UP;
  assert.deepEqual(h.writes, [], 'no event fired, so nothing has re-read yet');

  h.advance(APP_VIEWPORT_POLL_MS + 1);
  assert.deepEqual(h.writes, [`${APP_VIEWPORT_HEIGHT_VAR}=409px`], 'the poll must observe the settled state');
  stop();
});

test('installAppViewportHeightSync re-reads on a settling ladder after a mid-transient event', () => {
  // The only two events of a real keyboard raise fired mid-transient, 1ms apart, while
  // the viewport was still moving. Reading only at the event latches a wrong value, so
  // each event also schedules re-reads as it settles.
  const h = makeWindow({ innerHeight: 812, visualHeight: 812 });
  const stop = installAppViewportHeightSync(h.win);
  h.writes.length = 0;

  // Mid-transient: the visual viewport is momentarily 600 on its way down to 409.
  h.vv!.height = 600;
  h.emit('vv', 'resize');
  assert.deepEqual(h.writes, [`${APP_VIEWPORT_HEIGHT_VAR}=600px`], 'the transient is written first');

  // It settles. Still no further event.
  h.vv!.height = DEVICE_VISUAL_HEIGHT_KEYBOARD_UP;
  h.advance(APP_VIEWPORT_SETTLE_DELAYS_MS[0] + 1);
  assert.deepEqual(
    h.writes,
    [`${APP_VIEWPORT_HEIGHT_VAR}=600px`, `${APP_VIEWPORT_HEIGHT_VAR}=409px`],
    'the first ladder rung must correct the latched transient',
  );
  stop();
});

test('installAppViewportHeightSync suppresses no-op writes', () => {
  // This is what makes a standing 250ms poll free: a steady state costs two property
  // reads and an integer compare, and never invalidates layout.
  const h = makeWindow({ innerHeight: 812, visualHeight: 409 });
  const stop = installAppViewportHeightSync(h.win);
  assert.equal(h.writes.length, 1);
  h.advance(10 * APP_VIEWPORT_POLL_MS);
  h.emit('vv', 'resize');
  h.emit('vv', 'scroll');
  h.emit('win', 'resize');
  h.emit('win', 'focusin');
  assert.equal(h.writes.length, 1, 'an unchanged height must not be rewritten');
  stop();
});

test('installAppViewportHeightSync listens on every signal that precedes a keyboard transition', () => {
  const h = makeWindow({ innerHeight: 812, visualHeight: 812 });
  const stop = installAppViewportHeightSync(h.win);
  for (const [which, type] of [
    ['vv', 'resize'], ['vv', 'scroll'],
    ['win', 'resize'], ['win', 'orientationchange'], ['win', 'focusin'], ['win', 'focusout'],
  ] as const) {
    h.writes.length = 0;
    h.vv!.height = h.vv!.height === 409 ? 410 : 409; // force a change so a write is observable
    h.emit(which, type);
    assert.equal(h.writes.length, 1, `${which}:${type} must trigger a re-read`);
  }
  stop();
});

test('installAppViewportHeightSync teardown removes every listener and timer', () => {
  const h = makeWindow({ innerHeight: 812, visualHeight: 812 });
  const stop = installAppViewportHeightSync(h.win);
  h.emit('vv', 'resize'); // schedules the settling ladder
  assert.ok(h.listenerCount() > 0);
  assert.ok(h.timerCount() > 0);
  stop();
  assert.equal(h.listenerCount(), 0, 'no listener may outlive teardown');
  assert.equal(h.timerCount(), 0, 'no timer may outlive teardown');

  // And nothing writes after teardown even if a stray callback is already in flight.
  h.writes.length = 0;
  h.vv!.height = 409;
  h.advance(10 * APP_VIEWPORT_POLL_MS);
  assert.deepEqual(h.writes, []);
});

test('installAppViewportHeightSync works with no visualViewport at all', () => {
  const h = makeWindow({ innerHeight: 900, visualHeight: null });
  const stop = installAppViewportHeightSync(h.win);
  assert.deepEqual(h.writes, [`${APP_VIEWPORT_HEIGHT_VAR}=900px`]);
  assert.equal(readAppViewportHeight(h.win), 900);
  stop();
});
