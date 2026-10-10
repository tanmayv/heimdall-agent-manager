import React, { useEffect, useState } from 'react';
import Icon from '../Icon';
import { apiUrl } from '../../api/cookieFetch';

/** Fetch through the authenticated API so desktop bearer sessions work too. */
export default function ProviderIcon({ provider, size = 16 }: { provider: string; size?: number }) {
  const [image, setImage] = useState<{ provider: string; url: string } | null>(null);
  useEffect(() => {
    if (!provider) return;
    const controller = new AbortController();
    let objectUrl: string | undefined;
    void fetch(apiUrl(`/providers/${encodeURIComponent(provider)}/icon`), { credentials: 'include', signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) return;
        const blob = await response.blob();
        if (controller.signal.aborted) return;
        objectUrl = URL.createObjectURL(blob);
        setImage({ provider, url: objectUrl });
      }).catch(() => {});
    return () => { controller.abort(); if (objectUrl) URL.revokeObjectURL(objectUrl); };
  }, [provider]);

  return image?.provider === provider ? (
    <img data-debug-id={`provider-icon-${provider}`} src={image.url} alt="" aria-hidden="true" width={size} height={size} className="shrink-0 object-contain" onError={() => setImage(null)} />
  ) : <Icon name="spark" size={size} className="shrink-0 text-muted" />;
}
