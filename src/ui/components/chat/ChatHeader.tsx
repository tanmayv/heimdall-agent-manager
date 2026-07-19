import type { ReactNode } from 'react';

export default function ChatHeader({
  className = '',
  left,
  title,
  subtitle,
  status,
  actions,
  bottom,
}: {
  className?: string;
  left?: ReactNode;
  title: ReactNode;
  subtitle?: ReactNode;
  status?: ReactNode;
  actions?: ReactNode;
  bottom?: ReactNode;
}) {
  return (
    <div className={className || 'border-b border-[#262626] px-[18px] py-3'}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex items-start gap-3">
          {left ? <div className="shrink-0">{left}</div> : null}
          <div className="min-w-0">
            <div className="min-w-0 text-zinc-100">{title}</div>
            {subtitle ? <div className="mt-1 min-w-0 text-[12.5px] text-zinc-500">{subtitle}</div> : null}
          </div>
        </div>
        {(status || actions) ? (
          <div className="flex shrink-0 flex-wrap items-center justify-end gap-2">
            {status}
            {actions}
          </div>
        ) : null}
      </div>
      {bottom ? <div className="mt-3">{bottom}</div> : null}
    </div>
  );
}
