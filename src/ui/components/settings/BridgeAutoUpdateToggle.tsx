import { useEffect, useState } from 'react';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';

export default function BridgeAutoUpdateToggle({ bridgeId, online }: { bridgeId: string; online: boolean }) {
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const path = `/bridges/${encodeURIComponent(bridgeId)}/auto-update`;
  useEffect(() => {
    let active = true;
    setEnabled(null);
    setError('');
    if (online) {
      void cookieJsonFetch(path).then((reply: any) => {
        const data = reply?.data ?? reply;
        if (active && typeof data?.enabled === 'boolean') setEnabled(data.enabled);
      }).catch((err: any) => { if (active) setError(String(err?.message || 'Could not load automatic updates')); });
    }
    return () => { active = false; };
  }, [path, online]);

  async function save(value: boolean) {
    setSaving(true);
    setError('');
    try {
      const reply: any = await cookieMutation(path, 'PUT', { enabled: value });
      const data = reply?.data ?? reply;
      if (typeof data?.enabled !== 'boolean') throw new Error('Bridge did not confirm the setting');
      setEnabled(data.enabled);
    } catch (err: any) {
      setError(String(err?.message || 'Could not save automatic updates'));
    } finally {
      setSaving(false);
    }
  }

  return <div className="text-xs text-muted" data-debug-id={`settings-bridge-auto-update-${bridgeId}`}>
    <label className="inline-flex items-center gap-2">
      <input type="checkbox" data-debug-id={`settings-bridge-auto-update-toggle-${bridgeId}`}
        checked={enabled === true} disabled={!online || enabled === null || saving}
        onChange={(event) => void save(event.target.checked)} />
      Automatic bridge updates{!online ? ' (connect to change)' : enabled === null ? ' (loading…)' : ''}
    </label>
    <p>Checks about every 6 hours and installs when no agents are running.</p>
    {error ? <p role="alert">{error}</p> : null}
  </div>;
}
