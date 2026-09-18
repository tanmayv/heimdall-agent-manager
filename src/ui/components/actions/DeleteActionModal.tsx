import { Button, Modal } from '@ui';
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
  if (!action) return null;

  return (
    <Modal
      open={isOpen}
      onOpenChange={(next) => {
        if (!next) onClose();
      }}
      size="sm"
      title="Delete Action"
      data-debug-id="delete-action-modal"
    >
      <Modal.Body className="space-y-4">
        <p className="text-sm text-primary">
          Are you sure you want to delete this action? This will stop future scheduled executions and remove the action permanently.
        </p>

        <div className="rounded-lg border border-subtle bg-surface p-3">
          <p className="text-xs text-muted font-mono line-clamp-3">"{action.prompt_text}"</p>
        </div>
      </Modal.Body>
      <Modal.Footer>
        <Button variant="secondary" data-debug-id="delete-action-cancel-btn" disabled={isDeleting} onClick={onClose}>
          Cancel
        </Button>
        <Button variant="danger" data-debug-id="delete-action-confirm-btn" disabled={isDeleting} onClick={onConfirm}>
          {isDeleting ? 'Deleting...' : 'Delete Action'}
        </Button>
      </Modal.Footer>
    </Modal>
  );
}
