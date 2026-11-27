import type { ReactNode } from 'react';
import { IconButton } from '@ui';

export default function ViewerHeader({ title, titleControl, onBack, children }: {
  title: string;
  titleControl?: ReactNode;
  onBack: () => void;
  children?: ReactNode;
}) {
  return (
    <header className="relative z-10 flex min-h-14 shrink-0 items-center gap-2 bg-canvas/90 px-3 py-2 shadow-sm backdrop-blur-md sm:min-h-12 sm:gap-3 sm:px-4">
      <div aria-hidden="true" className="pointer-events-none absolute inset-x-0 -bottom-6 h-6 bg-gradient-to-b from-canvas/90 via-canvas/50 to-transparent backdrop-blur-sm" />
      <IconButton icon="arrow-left" label="Back" onClick={onBack} />
      {titleControl ? <div className="min-w-0 flex-1 [&>div]:block">
        <h1 className="sr-only">{title}</h1>
        {titleControl}
      </div> : <h1 className="min-w-0 flex-1 truncate text-base font-semibold text-primary" title={title}>{title}</h1>}
      {children}
    </header>
  );
}
