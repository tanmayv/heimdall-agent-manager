import React, { createContext, useContext } from 'react';

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
