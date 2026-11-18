import React, { useEffect, useId, useRef, useState } from 'react';
import { Icon } from '@ui';
import { useAuthAccounts, type AuthUserIdentity } from '../auth/AuthUserContext';

export default function AccountSwitcher({ user, avatar, isMobile, planLabel, openAccountSettings }: {
  user: AuthUserIdentity;
  avatar: React.ReactNode;
  isMobile: boolean;
  planLabel: string;
  openAccountSettings: () => void;
}) {
  const { accounts, switchAccount, addAccount, signOutAccount } = useAuthAccounts();
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  const toggle = useRef<HTMLButtonElement>(null);
  const menuId = useId();
  const displayName = user.display_name || user.name || user.user_id || 'Current user';
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => {
      if (!container.current?.contains(event.target as Node)) setOpen(false);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') { setOpen(false); toggle.current?.focus(); }
    };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('keydown', escape);
    return () => {
      document.removeEventListener('pointerdown', outside);
      document.removeEventListener('keydown', escape);
    };
  }, [open]);

  return <div ref={container} className="relative">
    <div data-debug-id="shell-global-ownership-points" className="flex items-center gap-2 rounded-xl px-2 py-1.5">
      {avatar}
      <button type="button" data-debug-id="shell-open-account" aria-label="Open account settings" onClick={openAccountSettings} className="min-w-0 flex-1 rounded-lg text-left focus-visible:outline-none focus-visible:shadow-focus hover:bg-neutral-soft">
        <div data-debug-id="shell-current-user-owner" className={`truncate font-semibold text-primary ${isMobile ? 'text-[14px]' : 'text-[12px]'}`}>{displayName}</div>
        <div className={`truncate text-muted ${isMobile ? 'text-[12px]' : 'text-[10.5px]'}`}>{user.email || user.user_id || ''}</div>
      </button>
      <button ref={toggle} type="button" data-debug-id="account-switcher-toggle" aria-label="Signed-in accounts" aria-expanded={open} aria-controls={menuId} onClick={() => setOpen(!open)} className={`flex shrink-0 items-center justify-center gap-1 rounded-lg text-muted hover:bg-neutral-soft focus-visible:outline-none focus-visible:shadow-focus ${isMobile ? 'h-11 min-w-11' : 'p-1.5'}`}>
        {accounts.length > 1 && <span className="text-xs font-semibold">{accounts.length}</span>}
        <Icon name="chevron-down" size={14} />
      </button>
      <button type="button" data-debug-id="auth-logout-link" onClick={() => { void signOutAccount(); }} title="Sign out" aria-label="Sign out" className={`grid shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary ${isMobile ? 'h-11 w-11 rounded-full' : 'rounded-lg p-1.5'}`}><Icon name="close" size={isMobile ? 18 : 14} /></button>
    </div>
    {open && <div id={menuId} data-debug-id="account-switcher-menu" aria-label="Signed-in accounts" className="absolute bottom-full left-0 z-50 mb-2 max-h-[60vh] w-full min-w-64 overflow-y-auto rounded-xl border border-subtle bg-surface p-2 shadow-lg">
      <p className="px-2 py-1 text-xs font-semibold text-muted">Signed-in accounts</p>
      {accounts.map(account => <div key={account.user_id} className="flex items-center gap-1">
        <button type="button" data-debug-id={`account-switcher-item-${account.user_id}`} disabled={account.active} onClick={() => { setOpen(false); void switchAccount(account.user_id); }} className="min-w-0 flex-1 rounded-lg p-2 text-left hover:bg-neutral-soft disabled:cursor-default">
          <span className="block truncate text-sm font-semibold text-primary">{account.display_name || account.name || account.user_id}{account.active && <span className="ml-2 text-xs text-muted">Active</span>}</span>
          <span className="block truncate text-xs text-muted">{account.email || account.user_id}</span>
        </button>
        <button type="button" data-debug-id={`account-switcher-logout-${account.user_id}`} aria-label={`Sign out ${account.display_name || account.name || account.user_id}`} onClick={() => { setOpen(false); void signOutAccount({ userId: account.user_id }); }} className="rounded-lg p-2 text-xs text-muted hover:bg-neutral-soft">Sign out</button>
      </div>)}
      <div className="mt-1 border-t border-subtle pt-1">
        <button type="button" data-debug-id="account-switcher-add-account" onClick={() => { setOpen(false); addAccount(); }} className="w-full rounded-lg p-2 text-left text-sm text-primary hover:bg-neutral-soft">Add another account</button>
        {accounts.length > 1 && <button type="button" data-debug-id="account-switcher-logout-all" onClick={() => { setOpen(false); void signOutAccount({ all: true }); }} className="w-full rounded-lg p-2 text-left text-sm text-danger hover:bg-neutral-soft">Sign out all accounts</button>}
      </div>
    </div>}
    {planLabel ? <button type="button" data-debug-id="shell-subscription-tier" aria-label={`Subscription: ${planLabel}. Open account settings`} onClick={openAccountSettings} className="mt-1 flex w-full items-center gap-2 rounded-lg px-2 py-1 text-left text-[11px] text-muted hover:bg-neutral-soft hover:text-primary focus-visible:outline-none focus-visible:shadow-focus">
      <Icon name="sparkle" size={12} className="shrink-0 text-accent" />
      <span className="truncate">Plan · <span className="font-semibold text-primary">{planLabel}</span></span>
    </button> : null}
  </div>;
}
