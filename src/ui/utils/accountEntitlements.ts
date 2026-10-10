/** Hub-resolved parameters. Feature consumers must not branch on plan IDs. */
export interface UserEntitlements {
  max_bridges: number;
  terminal_streaming_enabled: boolean;
}

export function describeEntitlements(params: UserEntitlements): string {
  return `${params.max_bridges} ${params.max_bridges === 1 ? 'bridge' : 'bridges'} · Terminal streaming ${params.terminal_streaming_enabled ? 'included' : 'not included'}`;
}
