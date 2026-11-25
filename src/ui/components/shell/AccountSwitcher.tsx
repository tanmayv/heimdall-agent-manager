import React, { useEffect, useId, useRef, useState } from 'react';
import { Icon, IconButton, Menu } from '@ui';
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
      <div className="min-w-0 flex-1">
        <div data-debug-id="shell-current-user-owner" className={`truncate font-semibold text-primary ${isMobile ? 'text-[14px]' : 'text-[12px]'}`}>{displayName}</div>
        <div className={`truncate text-muted ${isMobile ? 'text-[12px]' : 'text-[10.5px]'}`}>{user.email || user.user_id || ''}</div>
      </div>
      <IconButton icon="gear" label="Settings" data-debug-id="shell-open-account" onClick={openAccountSettings} className="shrink-0" />
      <button ref={toggle} type="button" data-debug-id="account-switcher-toggle" aria-label="Switch account" aria-haspopup="menu" aria-expanded={open} aria-controls={open ? menuId : undefined} onClick={() => setOpen(!open)} className="flex h-11 w-11 shrink-0 flex-col items-center justify-center rounded-lg text-muted hover:bg-neutral-soft focus-visible:outline-none focus-visible:shadow-focus">
        <Icon name="chevron-up" size={12} />
        <Icon name="chevron-down" size={12} />
      </button>
    </div>
    {open && <Menu.Panel id={menuId} data-debug-id="account-switcher-menu" label="Signed-in accounts" onClose={(restoreFocus) => { setOpen(false); if (restoreFocus) toggle.current?.focus(); }} className="absolute bottom-full right-0 z-50 mb-2 max-h-[60vh] w-full min-w-64 overflow-y-auto rounded-xl border border-subtle bg-surface p-2 shadow-lg">
      <Menu.Label>Signed-in accounts</Menu.Label>
      {accounts.map(account => <Menu.RadioItem key={account.user_id} data-debug-id={`account-switcher-item-${account.user_id}`} checked={account.active} disabled={account.active} description={account.email || account.user_id} onClick={() => { void switchAccount(account.user_id); }} className="min-h-11">
        {account.display_name || account.name || account.user_id}
      </Menu.RadioItem>)}
      <Menu.Separator />
      <Menu.Item data-debug-id="account-switcher-add-account" leading={<Icon name="plus" />} onClick={addAccount} className="min-h-11">Add another account</Menu.Item>
      <Menu.Item data-debug-id="account-switcher-logout-current" danger onClick={() => { void signOutAccount(); }} className="min-h-11">Log out of current account</Menu.Item>
      {accounts.length > 1 && <Menu.Item data-debug-id="account-switcher-logout-all" danger onClick={() => { void signOutAccount({ all: true }); }} className="min-h-11">Log out of all accounts</Menu.Item>}
    </Menu.Panel>}
    {planLabel ? <button type="button" data-debug-id="shell-subscription-tier" aria-label={`Subscription: ${planLabel}. Open account settings`} onClick={openAccountSettings} className="mt-1 flex w-full items-center gap-2 rounded-lg px-2 py-1 text-left text-[11px] text-muted hover:bg-neutral-soft hover:text-primary focus-visible:outline-none focus-visible:shadow-focus">
      <Icon name="sparkle" size={12} className="shrink-0 text-accent" />
      <span className="truncate">Plan · <span className="font-semibold text-primary">{planLabel}</span></span>
    </button> : null}
  </div>;
}
