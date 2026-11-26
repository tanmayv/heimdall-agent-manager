import { useEffect, useRef, useState } from 'react';
import { getExpectedUserGeneration, getExpectedUserId } from '../../utils/expectedUser';
import { defaultHomeLayout, HomeLayoutSession, type HomeLayout, type HomeLayoutAdapter, type HomeLayoutSnapshot } from './homeLayout';
import { createServerHomeLayoutAdapter } from './serverHomeLayoutAdapter';

const serverAdapter = createServerHomeLayoutAdapter();
const initialSnapshot = (): HomeLayoutSnapshot => ({ layout: defaultHomeLayout(), status: 'loading', canEdit: false });
export function useHomeLayout(userId: string, adapter: HomeLayoutAdapter = serverAdapter) {
  const [state, setState] = useState({ userId, adapter, snapshot: initialSnapshot() });
  const identity = useRef({ userId, adapter });
  identity.current = { userId, adapter };
  const session = useRef<HomeLayoutSession | undefined>(undefined);
  useEffect(() => {
    const generation = getExpectedUserGeneration();
    const isCurrentUser = () => identity.current.userId === userId && identity.current.adapter === adapter
      && (adapter !== serverAdapter || (getExpectedUserId() === userId && getExpectedUserGeneration() === generation));
    const next = new HomeLayoutSession(adapter, userId, (snapshot) => {
      if (session.current === next && isCurrentUser()) setState({ userId, adapter, snapshot });
    }, 500, isCurrentUser);
    session.current = next;
    void next.load();
    const refresh = () => { if (document.visibilityState === 'visible') void next.refresh(); };
    window.addEventListener('focus', refresh);
    window.addEventListener('online', refresh);
    document.addEventListener('visibilitychange', refresh);
    return () => {
      window.removeEventListener('focus', refresh);
      window.removeEventListener('online', refresh);
      document.removeEventListener('visibilitychange', refresh);
      next.dispose();
      if (session.current === next) session.current = undefined;
    };
  }, [adapter, userId]);
  return {
    ...(state.userId === userId && state.adapter === adapter ? state.snapshot : initialSnapshot()),
    edit: (change: (layout: HomeLayout) => HomeLayout) => session.current?.edit(change),
    reload: () => { void session.current?.load(); },
  };
}
