import { Action } from '../../api/endpoints/actions';

export type DeleteActionModalProps = {
  isOpen: boolean;
  action: Action | null;
  onClose: () => void;
  onConfirm: () => Promise<void>;
  isDeleting: boolean;
};

export default function DeleteActionModal({
  isOpen,
  action,
  onClose,
  onConfirm,
  isDeleting,
}: DeleteActionModalProps) {
  if (!isOpen || !action) return null;

  return (
    <div
      data-debug-id="delete-action-modal-overlay"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm animate-fade-in"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        data-debug-id="delete-action-modal"
        className="w-full max-w-md rounded-2xl border border-white/10 bg-[#121212] p-5 shadow-2xl space-y-4"
      >
        <div className="flex items-center justify-between">
          <h3 className="text-base font-semibold text-white">Delete Action</h3>
          <button
            type="button"
            onClick={onClose}
            className="text-zinc-400 hover:text-white transition-colors"
          >
            ✕
          </button>
        </div>

        <p className="text-sm text-zinc-300">
          Are you sure you want to delete this action? This will stop future scheduled executions and remove the action permanently.
        </p>

        <div className="rounded-lg border border-white/10 bg-black/30 p-3">
          <p className="text-xs text-zinc-400 font-mono line-clamp-3">
            "{action.prompt_text}"
          </p>
        </div>

        <div className="flex items-center justify-end gap-3 pt-2">
          <button
            type="button"
            data-debug-id="delete-action-cancel-btn"
            disabled={isDeleting}
            onClick={onClose}
            className="px-4 py-2 rounded-xl border border-white/10 bg-white/5 hover:bg-white/10 text-xs font-semibold text-zinc-300 transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            data-debug-id="delete-action-confirm-btn"
            disabled={isDeleting}
            onClick={onConfirm}
            className="px-4 py-2 rounded-xl bg-red-600 hover:bg-red-500 text-xs font-semibold text-white transition-colors disabled:opacity-50"
          >
            {isDeleting ? 'Deleting...' : 'Delete Action'}
          </button>
        </div>
      </div>
    </div>
  );
}
