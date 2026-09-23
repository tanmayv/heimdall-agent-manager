/**
 * ToastViewport — renders the app's toast queue as @ui Toast cards.
 * ------------------------------------------------------------------
 * The bridge between the existing Redux toast store (`store/toastSlice`) and the
 * presentational `@ui` Toast card. It portals a fixed, bottom-anchored stack of
 * the current toasts and dispatches `dismissToast` when one is dismissed (auto or
 * by the close button). Keeping the Redux queue (rather than a new Provider)
 * avoids duplicating the working showToast/dismiss infra.
 *
 * ALREADY MOUNTED, ONCE, in src/ui/main.tsx inside <Provider> and outside
 * ElectronDeviceAuthGate. Do NOT add a second mount (AppShell or elsewhere):
 * every mount renders the same queue, so a second one double-renders every
 * toast. This docstring previously said "mount near the app root" and nothing
 * ever did — see REQ-UI-TOAST-1.
 *
 * Accessibility: each `@ui` Toast is its own live region (role=status / alert),
 * so the container is a plain positioning wrapper (no nested live region). The
 * wrapper is pointer-events-none; the cards re-enable pointer events themselves.
 */
import { createPortal } from 'react-dom';
import { useDispatch, useSelector } from 'react-redux';
import { Toast } from '@ui';
import type { Tone } from '@ui';
import { dismissToast, type Toast as ToastData, type ToastKind } from '../store/toastSlice';

const KIND_TONE: Record<ToastKind, Tone> = {
  success: 'success',
  error: 'danger',
  info: 'info',
  progress: 'pending',
};

export function ToastViewport() {
  const toasts = useSelector((state: { toasts: { toasts: ToastData[] } }) => state.toasts.toasts);
  const dispatch = useDispatch();

  if (typeof document === 'undefined' || toasts.length === 0) return null;

  return createPortal(
    <div className="pointer-events-none fixed inset-x-0 bottom-0 z-toast flex flex-col items-center gap-2 p-4 sm:items-end">
      {toasts.map((t) => (
        <Toast
          key={t.id}
          tone={KIND_TONE[t.kind]}
          title={t.title}
          duration={t.autoDismissMs}
          onDismiss={() => dispatch(dismissToast(t.id))}
        >
          {t.message}
        </Toast>
      ))}
    </div>,
    document.body,
  );
}

export default ToastViewport;
