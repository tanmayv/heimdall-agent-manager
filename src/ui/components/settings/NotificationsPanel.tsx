import { useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  categoryEnabled,
  notificationCategorySet,
  notificationPermissionRefreshed,
  notificationPermissionSet,
  notificationsEnabledSet,
  selectNotificationsState,
} from '../../store/notificationsSlice';
import type { NotificationCategory } from '../../api/notificationMapper';
import {
  isElectronRuntime,
  isNotificationSupported,
  requestNotificationPermission,
  showNativeNotification,
} from '../../services/notificationService';
import { showToast } from '../../store/toastSlice';

const CATEGORY_LABELS: Array<{ key: NotificationCategory; label: string; description: string }> = [
  { key: 'chat', label: 'Chat messages', description: 'New messages directed to you, nudges, and mentions.' },
  { key: 'attention', label: 'Needs attention', description: 'Agent questions/approvals and pending merge decisions.' },
];

function Toggle({
  checked,
  onChange,
  disabled,
  debugId,
  label,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  disabled?: boolean;
  debugId: string;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      data-debug-id={debugId}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors ${
        checked ? 'bg-sky-400' : 'bg-white/15'
      } ${disabled ? 'cursor-not-allowed opacity-40' : 'cursor-pointer'}`}
    >
      <span
        className={`inline-block h-5 w-5 transform rounded-full bg-white shadow transition-transform ${
          checked ? 'translate-x-5' : 'translate-x-0.5'
        }`}
      />
    </button>
  );
}

// H11: the sample plan the Send-test-notification button fires through the real
// native path. Exported so tests can assert exactly what is shown.
export const TEST_NOTIFICATION_PLAN = {
  title: 'Heimdall test notification',
  body: 'If you can see this, notifications are working.',
  tag: 'heimdall-test',
  route: '#/settings',
  category: 'attention' as const,
};

// H11: pure helper computing the always-shown in-app toast message for the test
// button, covering every case (native fired / electron / unsupported / denied /
// default). Pure + exported so it is unit-testable without React.
export function testNotificationFeedback(opts: {
  nativeShown: boolean;
  electron: boolean;
  supported: boolean;
  permission: string;
}): string {
  if (opts.nativeShown) {
    return 'Sent a native notification. If your tab is focused the OS popup may be suppressed — this toast confirms the path fired.';
  }
  if (opts.electron) {
    return 'Desktop app handles native notifications; this in-app toast confirms the test fired.';
  }
  if (!opts.supported) {
    return 'This browser has no Notifications API; showing an in-app toast instead.';
  }
  if (opts.permission === 'denied') {
    return 'Notifications are blocked for this site — enable them in your browser settings. Showing an in-app toast for now.';
  }
  return 'Showing an in-app test notification.';
}

export default function NotificationsPanel() {
  const dispatch = useDispatch();
  const state = useSelector(selectNotificationsState);
  const supported = isNotificationSupported();
  const electron = isElectronRuntime();

  // Keep the stored permission in sync with the live browser state on mount and
  // when the tab regains visibility (the user may have changed it in browser
  // settings). This is feature-detection only — never requestPermission().
  useEffect(() => {
    dispatch(notificationPermissionRefreshed());
    const onVisibility = () => dispatch(notificationPermissionRefreshed());
    document.addEventListener('visibilitychange', onVisibility);
    return () => document.removeEventListener('visibilitychange', onVisibility);
  }, [dispatch]);

  const masterDisabled = !supported || electron || state.permission === 'denied';

  // H11: fire a real test notification so the user can confirm notifications
  // appear. It ALWAYS dispatches an in-app toast (visible feedback in every case:
  // focused tab, Electron, denied, or unsupported) and, when browser
  // notifications are supported + granted, also fires the real native path via
  // showNativeNotification. Non-throwing: any failure still yields a toast.
  async function onSendTest() {
    let nativeShown = false;
    let permission = state.permission;
    try {
      if (supported && !electron && permission === 'granted') {
        nativeShown = showNativeNotification(TEST_NOTIFICATION_PLAN);
      } else if (supported && !electron && permission === 'default') {
        // Explicit user gesture: it is safe to request permission here. If granted,
        // fire the native notification immediately.
        permission = await requestNotificationPermission();
        dispatch(notificationPermissionSet(permission));
        if (permission === 'granted') {
          nativeShown = showNativeNotification(TEST_NOTIFICATION_PLAN);
        }
      }
    } catch (_err) {
      // never throw from a test button; the toast below still fires.
      nativeShown = false;
    }
    // Always give visible in-app feedback.
    dispatch(showToast({
      kind: 'info',
      title: 'Test notification',
      message: testNotificationFeedback({ nativeShown, electron, supported, permission }),
    }));
  }

  async function onMasterToggle(next: boolean) {
    if (!next) {
      dispatch(notificationsEnabledSet(false));
      return;
    }
    // Turning ON: request permission from this explicit user gesture if needed.
    if (state.permission !== 'granted') {
      const result = await requestNotificationPermission();
      dispatch(notificationPermissionSet(result));
      if (result !== 'granted') return; // denied/unsupported => stay off, no error thrown
    }
    dispatch(notificationsEnabledSet(true));
  }

  const statusLine = electron
    ? 'Running in the desktop app — native notifications are handled by the app itself, so this browser setting is disabled.'
    : !supported
      ? 'This browser does not support the Web Notifications API. Notifications are unavailable here.'
      : state.permission === 'denied'
        ? 'Notifications are blocked for this site. Re-enable them in your browser site settings, then reload.'
        : state.permission === 'granted'
          ? 'Permission granted. You will be notified while this tab is open in the background.'
          : 'Permission not requested yet. Turn on notifications to grant permission.';

  return (
    <div data-debug-id="settings-notifications-panel" className="w-full max-w-3xl space-y-5 text-left">
      <div>
        <h2 className="text-xl font-semibold text-white">Notifications</h2>
        <p className="mt-1 text-sm text-zinc-400">
          Get a native browser notification for important events while this tab is open but not focused. When the tab is
          focused you will keep seeing in-app toasts instead.
        </p>
      </div>

      <div className="rounded-2xl border border-white/10 bg-black/20 p-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="font-semibold text-zinc-100">Enable browser notifications</div>
            <p className="mt-1 text-sm text-zinc-400" data-debug-id="settings-notifications-status">{statusLine}</p>
          </div>
          <Toggle
            checked={state.enabled}
            onChange={onMasterToggle}
            disabled={masterDisabled}
            debugId="settings-notifications-master-toggle"
            label="Enable browser notifications"
          />
        </div>
      </div>

      <div className={`rounded-2xl border border-white/10 bg-black/20 p-4 ${state.enabled ? '' : 'opacity-50'}`}>
        <div className="mb-3 text-sm font-semibold text-zinc-200">Categories</div>
        <div className="space-y-3">
          {CATEGORY_LABELS.map((cat) => (
            <div key={cat.key} className="flex items-start justify-between gap-4">
              <div>
                <div className="text-sm font-medium text-zinc-100">{cat.label}</div>
                <p className="mt-0.5 text-xs text-zinc-500">{cat.description}</p>
              </div>
              <Toggle
                checked={categoryEnabled(state, cat.key)}
                onChange={(next) => dispatch(notificationCategorySet({ category: cat.key, enabled: next }))}
                disabled={!state.enabled}
                debugId={`settings-notifications-category-${cat.key}`}
                label={cat.label}
              />
            </div>
          ))}
        </div>
      </div>

      <div className="rounded-2xl border border-white/10 bg-black/20 p-4">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="font-semibold text-zinc-100">Test notifications</div>
            <p className="mt-1 text-sm text-zinc-400">
              Send a sample notification to confirm they appear. You will get a native OS notification when supported and
              granted (and your tab is in the background), plus an in-app toast every time so you always see a result.
            </p>
          </div>
          <button
            type="button"
            data-debug-id="settings-notifications-test-btn"
            onClick={() => void onSendTest()}
            className="shrink-0 rounded-xl bg-sky-400 px-4 py-2 text-sm font-semibold text-black hover:bg-sky-300"
          >
            Send test notification
          </button>
        </div>
      </div>
    </div>
  );
}
