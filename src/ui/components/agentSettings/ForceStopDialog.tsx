/**
 * ForceStopDialog — the small confirmation for "Force stop" in the Runtime card.
 * Force stop kills the process at once, so it is confirmed; Stop and Restart are not.
 */
import React from 'react';
import { Button, Modal, Text } from '@ui';

export interface ForceStopDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConfirm: () => void;
  /** Agent label shown in the question, e.g. "coordinator #41". */
  agentLabel?: string;
}

export const FORCE_STOP_NOTE = 'Kills the process now. The current turn is lost.';

/** Confirming closes the dialog at once; progress shows in the Runtime card. */
export function ForceStopDialog({ open, onOpenChange, onConfirm, agentLabel }: ForceStopDialogProps) {
  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title={agentLabel ? `Force stop ${agentLabel}?` : 'Force stop the agent?'}
      size="sm"
      data-debug-id="agent-panel-force-stop-dialog"
    >
      <Modal.Body>
        <Text role="body-sm" tone="muted">{FORCE_STOP_NOTE}</Text>
      </Modal.Body>
      <Modal.Footer>
        <Button variant="ghost" data-debug-id="agent-panel-force-stop-cancel" onClick={() => onOpenChange(false)}>
          Cancel
        </Button>
        <Button
          variant="danger"
          data-debug-id="agent-panel-force-stop-confirm"
          onClick={() => {
            onConfirm();
            onOpenChange(false);
          }}
        >
          Force stop
        </Button>
      </Modal.Footer>
    </Modal>
  );
}

export default ForceStopDialog;
