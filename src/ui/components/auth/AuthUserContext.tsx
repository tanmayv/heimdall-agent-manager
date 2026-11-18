import React, { createContext, useContext } from 'react';
import type { AuthSessionAccount, LogoutAccountOptions } from '../../auth/oidcSession';

export type AuthUserIdentity = {
  user_id?: string;
  name?: string;
  display_name?: string;
  email?: string;
};

const AuthUserContext = createContext<AuthUserIdentity | null>(null);

export const AuthUserProvider = AuthUserContext.Provider;

export function useAuthUser(): AuthUserIdentity | null {
  return useContext(AuthUserContext);
}

// Unavailable (429/503) retries quietly; switching unmounts all account streams.
export type AuthStatus = 'checking' | 'authenticated' | 'switching' | 'unauthenticated' | 'forbidden' | 'unavailable' | 'error';
export type AuthState = { status: AuthStatus; user: AuthUserIdentity | null; error: string };

export type AuthAccounts = {
  accounts: AuthSessionAccount[];
  switchAccount: (userId: string) => Promise<void>;
  addAccount: () => void;
  signOutAccount: (opts?: LogoutAccountOptions) => Promise<void>;
};

const AuthAccountsContext = createContext<AuthAccounts>({
  accounts: [],
  switchAccount: async () => {},
  addAccount: () => {},
  signOutAccount: async () => {},
});

export const AuthAccountsProvider = AuthAccountsContext.Provider;

export function useAuthAccounts(): AuthAccounts {
  return useContext(AuthAccountsContext);
}
