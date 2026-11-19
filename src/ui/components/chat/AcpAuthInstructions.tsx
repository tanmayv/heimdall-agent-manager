export function AcpAuthInstructions({ profile, guidance }: { profile?: string; guidance?: string }) {
  if (guidance) return <p className="break-words text-sm text-primary">{guidance}</p>;
  return <p className="break-words text-sm text-primary">
    ACP authentication required. Authenticate this provider on the bridge host using the same
    environment and config directory as {profile ? <>profile <code>{profile}</code></> : 'this provider profile'}.
    {' '}Then restart this instance using the existing Restart agent control.
  </p>;
}
