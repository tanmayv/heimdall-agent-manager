import { useEffect, useRef, useState } from 'react';
import { createLocalHomeLayoutAdapter, defaultHomeLayout, HomeLayoutSession, type HomeLayout, type HomeLayoutAdapter, type HomeLayoutSnapshot } from './homeLayout';

const localAdapter: HomeLayoutAdapter = {
  load: (userId) => createLocalHomeLayoutAdapter(window.localStorage).load(userId),
  save: (userId, layout, version) => createLocalHomeLayoutAdapter(window.localStorage).save(userId, layout, version),
};
export function useHomeLayout(userId: string, adapter: HomeLayoutAdapter = localAdapter) {
  const [snapshot, setSnapshot] = useState<HomeLayoutSnapshot>({ layout: defaultHomeLayout(), status: 'loading' });
  const session = useRef<HomeLayoutSession | undefined>(undefined);
  useEffect(() => {
    const next = new HomeLayoutSession(adapter, userId, setSnapshot);
    session.current = next;
    void next.load();
    return () => { next.dispose(); };
  }, [adapter, userId]);
  return {
    ...snapshot,
    edit: (change: (layout: HomeLayout) => HomeLayout) => session.current?.edit(change),
    reload: () => { void session.current?.load(); },
  };
}
