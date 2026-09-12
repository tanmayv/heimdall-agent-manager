import React from 'react';

// Canonical modal shell: the fixed overlay + centered panel that every dialog in
// the app was re-inlining (ProjectLaunchModal, DeleteActionModal, the memory
// delete-confirm, etc.). It owns only the overlay + panel chrome and
// backdrop-click-to-close; callers compose their own header/body/footer as
// children. Behaviour is a faithful extraction of the dominant pattern — no focus
// trap / Esc handling is added here (that a11y work is a separate task).

type ModalSize = 'sm' | 'md' | 'lg' | 'xl';

const SIZE_MAX_W: Record<ModalSize, string> = {
  sm: 'max-w-md',
  md: 'max-w-lg',
  lg: 'max-w-2xl',
  xl: 'max-w-4xl',
};

export default function Modal({
  open,
  onClose,
  size = 'md',
  children,
  panelClassName = '',
  className = '',
  closeOnBackdrop = true,
  debugId,
  panelDebugId,
}: {
  open: boolean;
  onClose: () => void;
  size?: ModalSize;
  children: React.ReactNode;
  /** Extra classes for the panel (padding, layout, fixed height, …). */
  panelClassName?: string;
  /** Extra classes for the overlay. */
  className?: string;
  closeOnBackdrop?: boolean;
  debugId?: string;
  panelDebugId?: string;
}) {
  if (!open) return null;
  return (
    <div
      data-debug-id={debugId}
      className={`fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm animate-fade-in ${className}`.trim()}
      onClick={
        closeOnBackdrop
          ? (e) => {
              if (e.target === e.currentTarget) onClose();
            }
          : undefined
      }
    >
      <div
        data-debug-id={panelDebugId}
        className={`w-full ${SIZE_MAX_W[size]} rounded-2xl border border-white/10 bg-[#121212] shadow-2xl ${panelClassName}`.trim()}
      >
        {children}
      </div>
    </div>
  );
}
