import React, { useEffect, useState } from 'react';
import { Alert, Button, Panel, Text } from '@ui';
import { disconnectMcpConnection, fetchMcpConnections, type McpConnection } from '../../api/endpoints/mcp';
import { useSelector } from 'react-redux';
import { selectDeviceVault } from '../../store/deviceVaultSlice';
import { refreshConnectorEpochs } from '../../services/deviceVault';

export function McpConnections() {
  const deliveryError = useSelector(selectDeviceVault).mcpKeyDeliveryError;
  const [rows, setRows] = useState<McpConnection[]>([]);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [available, setAvailable] = useState(false);
  useEffect(() => {
    let active = true;
    fetchMcpConnections().then((data) => { if (active) { setRows(data); setAvailable(true); } }).catch(() => { /* Optional feature absent on ordinary Hubs. */ });
    return () => { active = false; };
  }, []);
  if (!available) return null;
  async function disconnect(grant: string) {
    setBusy(grant); setError('');
    try { await disconnectMcpConnection(grant); setRows(await fetchMcpConnections()); }
    catch { setError('Could not disconnect. Try again.'); }
    finally { setBusy(''); }
  }
  return <section className="mt-6 space-y-3" data-debug-id="settings-mcp-connections">
    <Text as="h2" role="heading">AI connections</Text>
    <Text as="p" role="body-sm">Disconnect here to stop future access. Removing a connector at your AI provider may leave its Ninjy grant active.</Text>
    {rows.filter((r) => !r.revoked).map((row) => <Panel key={row.grant} className="space-y-2">
      <Text as="p" role="code">{row.client}</Text>
      <Text as="p" role="body-sm">{row.mode === 'hosted' ? 'Hosted decryption allowed' : 'An approved device decrypts results'}</Text>
      <Button data-debug-id={`settings-mcp-disconnect-${row.grant}`} variant="danger" loading={busy === row.grant} disabled={!!busy} onClick={() => disconnect(row.grant)}>Disconnect</Button>
    </Panel>)}
    {!rows.some((r) => !r.revoked) && <Text as="p" role="body-sm">No active connections.</Text>}
    {rows.some((r) => !r.revoked && r.mode === 'hosted') && <Button data-debug-id="settings-mcp-deliver-keys" variant="secondary" disabled={!!busy} onClick={async () => { setBusy('delivery'); try { await refreshConnectorEpochs(); } finally { setBusy(''); } }}>Refresh decryption keys</Button>}
    {deliveryError && <Alert tone="warning" title="Key delivery needed">{deliveryError}</Alert>}
    {error && <Alert tone="danger" title="Connection unavailable">{error}</Alert>}
  </section>;
}
