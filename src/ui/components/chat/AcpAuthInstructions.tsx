export function AcpAuthInstructions({ profile }: { profile?: string }) {
  return <p className="break-words text-sm text-primary">
    ACP authentication required. Run <code>claude /login</code> on the bridge host using the same
    environment and config directory as {profile ? <>profile <code>{profile}</code></> : 'this provider profile'}.
    {' '}Then restart this instance using the existing Restart agent control.
  </p>;
}
