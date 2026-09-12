import Icon from '../Icon';
import Modal from '../Modal';
import { Button } from '@ui';
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
    <Modal
      open={isOpen}
      onClose={onClose}
      size="sm"
      panelClassName="p-5 space-y-4"
      debugId="delete-action-modal-overlay"
      panelDebugId="delete-action-modal"
    >
        <div className="flex items-center justify-between">
          <h3 className="text-base font-semibold text-white">Delete Action</h3>
          <button
            type="button"
            aria-label="Close"
            onClick={onClose}
            className="text-zinc-400 hover:text-white transition-colors"
          >
            <Icon name="close" size={16} />
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
          <Button
            variant="secondary"
            data-debug-id="delete-action-cancel-btn"
            disabled={isDeleting}
            onClick={onClose}
          >
            Cancel
          </Button>
          <Button
            variant="danger"
            data-debug-id="delete-action-confirm-btn"
            disabled={isDeleting}
            onClick={onConfirm}
          >
            {isDeleting ? 'Deleting...' : 'Delete Action'}
          </Button>
        </div>
    </Modal>
  );
}
