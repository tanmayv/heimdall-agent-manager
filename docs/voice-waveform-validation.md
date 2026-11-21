# Voice waveform implementation and validation

The shared voice recorder panel and audio player show measured amplitude bars in both agent
and bot composers. Artifact decryption, transcripts, MIME negotiation, explicit preview/send,
and the existing 10-minute / 15 MiB recording limits retain their existing owners.

## Analysis budgets and fallback

- Recording uses the acquired microphone stream, one owned AudioContext, a 256-sample reused
  float array, and at most 64 measured history entries, sampled at most 20 times per second.
  Hidden documents skip measurements. Reduced motion shows the current measured level without
  moving history. Sources/analyser disconnect, frames cancel, and the context closes through
  the existing stop/cancel/error/limit/unmount cleanup.
- Playback reads only the existing decrypted blob URL, on visibility when IntersectionObserver
  exists. A finite positive duration of at most 60 seconds must be known before fetching or
  decoding. Streaming input is capped at 8 MiB. One decode runs at a time; there is no queued
  blob/PCM cache. Waiting visible players retry when the slot becomes available.
- Decode requests 16 kHz output. The admitted output estimate is at most 123 MiB for 60 seconds
  and 32 channels. Decoded duration, channel count and rate are checked again before scanning.
  Browser metadata can be incorrect and decoder internals cannot be hard-capped by this API:
  this is a conservative admission strategy, not a security boundary or a hard browser RSS cap.
- At most 128 compact peaks are retained per mounted player, with no shared URL or peak cache.
  Rendering combines real neighboring maxima into 8–64 responsive rounded bars. No random or
  synthesized waveform data enters production. Stale/aborted results cannot publish; abort
  closes the owned decode context immediately, while the serialization slot remains held
  until the uncancellable decoder promise settles.
- Unknown-duration, longer, oversize, unsupported or failed decoding retains HTML audio
  playback and the labeled native seek range. Unknown duration disables seeking until known.
  Analysis never invokes play, microphone acquisition or upload; it never revokes parent URLs.
- Native range input provides pointer drag/release/cancel, touch and keyboard interaction with
  elapsed/total accessible text. Bars are decorative. Playback and recorder buttons use
  44 CSS pixel targets and action rows wrap at narrow widths.

The modest adjacent lifecycle repair prevents a cancelled recorder's late stop event from
releasing a subsequently acquired microphone stream.

## Repeatable checks

~~~bash
node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_voice_messages_test.ts
npm run typecheck
npm run build
npm test
~~~

An optional browser runner builds an isolated fixture using the production shared components,
the real browser MediaRecorder and decoder, a generated Web Audio microphone stream and a
known PCM WAV fixture. It requires an independently installed Playwright package/browser;
it adds no production dependency. It builds its own local HTML and CSS and runs via file URL.
Override the executable only when the locally installed browser version differs.

~~~bash
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs \
CHROMIUM_EXECUTABLE=/path/to/chrome-headless-shell \
node tests/voice-waveforms-browser.mjs
~~~

Evidence is written to /tmp/voice-waveform-evidence: results JSON, recording/playback PNGs at
320, 768 and 1024 pixels, and playback at 320 pixels with 200% zoom. The browser assertions cover
decoded silence/nonzero peaks, quiet/loud analyser measurements, one stream per recording,
no send side effect, real preview decoding/play/pause, touch tap, keyboard Home/End/arrow,
dragging outside the track, recovery after a dispatched pointer cancel, and layout overflow.
The pointer-cancel check dispatches the cancellation event; it does not emulate an OS gesture
interruption. These are shared-component fixtures, not authenticated whole-chat screenshots.

## Physical Safari/iPad validation still required

Chromium automation and mocked decode rejection do not establish physical Safari compatibility.
There is no physical iPad microphone, Safari session, VoiceOver or Electron/macOS check here.

1. On iPad Safari, open an agent chat and a bot chat; record speech, silence and a louder phrase.
   Confirm one permission request and real changing bars. Deny permission, cancel during the
   prompt, retry, stop, discard and navigate away; confirm the microphone indicator clears.
2. Repeat after background/foreground and an audio interruption. Test portrait, landscape,
   increased text size, 200% zoom, reduced motion and VoiceOver announcements/seek controls.
3. Preview the browser-selected codec (including MP4/AAC when Safari chooses it), fetched
   Ogg/Opus, WebM/Opus and WAV. Confirm unsupported peak decoding leaves playable audio and
   duration-based seeking. Test a clip longer than 60 seconds and one over 8 MiB for fallback.
4. Touch-drag to both endpoints and outside the track, interrupt/cancel the drag, and seek again.
   Confirm no playback starts until Play and no attachment uploads until Send.
5. Send a voice note and inspect a decrypted incoming voice attachment with transcript. Confirm
   existing vault-lock, transcript and retry behavior, then repeat recording several times.
