import { useEffect, useRef } from 'react';
import { desktopCapabilities } from '../../bridge/desktopBridge';
import { buildRouteHash } from '../../utils/appLocation';
import { setupSeen } from './setupWizardModel';

/** Check the launch route once; explicit deep links keep their destination. */
export function useSetupRedirect(path: string, userId: string): void {
  const checked = useRef(false);
  useEffect(() => {
    if (checked.current) return;
    checked.current = true;
    if (path !== '/home' || !desktopCapabilities().desktop || setupSeen(userId)) return;
    window.location.hash = buildRouteHash('/setup', '');
  }, [path, userId]);
}
