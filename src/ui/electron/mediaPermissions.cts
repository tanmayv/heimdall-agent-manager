// REQ-VOICE-4: microphone access for voice messages. The renderer's getUserMedia({ audio })
// is granted only to the app's own UI origin (the main frame of the Hub UI, or the Vite
// dev server in development); camera and every other origin are refused. Permissions
// other than `media` keep Electron's default (granted), as before this handler existed.

function originOf(value: unknown): string {
  try { return new URL(String(value || '')).origin; } catch (_err) { return ''; }
}

function trustedOrigin(url: unknown, trustedOrigins: string[]): boolean {
  const origin = originOf(url);
  if (!origin || origin === 'null') return false;
  return trustedOrigins.some((candidate) => originOf(candidate) === origin);
}

/** Request: allow `media` only for audio, from a trusted origin's main frame. */
function mediaRequestAllowed(permission: string, details: any, trustedOrigins: string[]): boolean | null {
  if (permission !== 'media') return null;
  const types: string[] = Array.isArray(details?.mediaTypes) ? details.mediaTypes : [];
  if (types.length === 0 || types.some((type) => type !== 'audio')) return false;
  if (details?.isMainFrame === false) return false;
  return trustedOrigin(details?.requestingUrl || details?.securityOrigin, trustedOrigins);
}

/** Check (permissions.query, enumerateDevices): audio, or unspecified, from a trusted origin. */
function mediaCheckAllowed(permission: string, requestingOrigin: string, details: any, trustedOrigins: string[]): boolean | null {
  if (permission !== 'media') return null;
  const type = String(details?.mediaType || 'unknown');
  if (type !== 'audio' && type !== 'unknown') return false;
  return trustedOrigin(requestingOrigin || details?.securityOrigin || details?.requestingUrl, trustedOrigins);
}

/**
 * Installs the handlers on `session`. On macOS the system prompt (NSMicrophoneUsageDescription)
 * is asked for before granting, so a refusal in System Settings reaches the page as
 * NotAllowedError rather than a silent, empty stream.
 */
function installMediaPermissions({ session, trustedOrigins, systemPreferences, platform = process.platform }: {
  session: any;
  trustedOrigins: () => string[];
  systemPreferences?: any;
  platform?: string;
}) {
  session.setPermissionRequestHandler((_webContents: any, permission: string, callback: (granted: boolean) => void, details: any) => {
    const decision = mediaRequestAllowed(permission, details, trustedOrigins());
    if (decision === null) { callback(true); return; }
    if (!decision) {
      console.warn(`[heimdall] refused ${permission} (${(details?.mediaTypes || []).join(',') || 'unspecified'}) for ${String(details?.requestingUrl || 'an unknown origin')}`);
      callback(false);
      return;
    }
    if (platform !== 'darwin' || !systemPreferences?.getMediaAccessStatus) { callback(true); return; }
    const status = systemPreferences.getMediaAccessStatus('microphone');
    if (status === 'granted') { callback(true); return; }
    if (status !== 'not-determined' || !systemPreferences.askForMediaAccess) { callback(false); return; }
    Promise.resolve(systemPreferences.askForMediaAccess('microphone'))
      .then((granted: boolean) => callback(Boolean(granted)))
      .catch(() => callback(false));
  });
  session.setPermissionCheckHandler((_webContents: any, permission: string, requestingOrigin: string, details: any) => {
    const decision = mediaCheckAllowed(permission, requestingOrigin, details, trustedOrigins());
    return decision === null ? true : decision;
  });
}

module.exports = { installMediaPermissions, mediaRequestAllowed, mediaCheckAllowed };
