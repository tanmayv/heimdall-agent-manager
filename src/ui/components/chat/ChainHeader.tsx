import React, { useState } from 'react';
import { Badge, StatusPill, type Tone } from '@ui';
import { FleetSlotChips, FleetManagementDrawer } from '../tasks/FleetManagementDrawer';

export interface ChainHeaderProps {
  chainId: string;
  title?: string;
  status?: string;
  onOpenFleetDrawer?: () => void;
  className?: string;
}

function statusTone(status?: string): Tone {
  const s = String(status || '').toLowerCase();
  if (s === 'completed' || s === 'validated_good') return 'success';
  if (s === 'cancelled' || s === 'failed') return 'danger';
  if (s === 'in_progress' || s === 'in_validation') return 'info';
  if (s === 'queued' || s === 'paused') return 'warning';
  return 'neutral';
}

export const ChainHeader: React.FC<ChainHeaderProps> = ({
  chainId,
  title,
  status,
  onOpenFleetDrawer,
  className = '',
}) => {
  const [internalDrawerOpen, setInternalDrawerOpen] = useState(false);

  const handleOpen = () => {
    if (onOpenFleetDrawer) {
      onOpenFleetDrawer();
    } else {
      setInternalDrawerOpen(true);
    }
  };

  return (
    <div
      data-debug-id="chain-header"
      className={`flex flex-wrap items-center justify-between gap-2.5 border-b border-subtle px-3 py-2.5 bg-canvas/80 backdrop-blur-sm max-w-full min-w-0 ${className}`}
    >
      <div className="flex items-center gap-2 min-w-0">
        {title && (
          <h2
            data-debug-id="chain-header-title"
            className="text-xs font-bold text-primary truncate max-w-[200px] sm:max-w-xs"
          >
            {title}
          </h2>
        )}
        {status && (
          <StatusPill tone={statusTone(status)}>
            {status}
          </StatusPill>
        )}
      </div>

      <div className="flex flex-wrap items-center gap-2 max-w-full">
        <FleetSlotChips
          chainId={chainId}
          onOpenDrawer={handleOpen}
        />
      </div>

      <FleetManagementDrawer
        chainId={chainId}
        isOpen={internalDrawerOpen}
        onClose={() => setInternalDrawerOpen(false)}
      />
    </div>
  );
};

export default ChainHeader;
