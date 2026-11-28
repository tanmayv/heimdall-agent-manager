// Delivery result of a user message to an agent, mirroring the hub's
// Message_Delivery_Wire (src/contracts/message_delivery.odin). POST
// /chats/{id}/messages returns it as the message's `delivery`; MCP
// chains.message reports the same state as `status` with the reason in
// `delivery_warning`. A message to a stopped or dead agent is never accepted.
export const MESSAGE_DELIVERY_ACCEPTED = 'accepted';
export const MESSAGE_DELIVERY_PENDING = 'pending';

export type MessageDeliveryState = typeof MESSAGE_DELIVERY_ACCEPTED | typeof MESSAGE_DELIVERY_PENDING;

export type MessageDeliveryReason =
  | ''
  | 'agent_not_found'
  | 'agent_not_running'
  | 'agent_starting'
  | 'agent_start_failed'
  | 'agent_manually_stopped'
  | 'provider_unavailable'
  | 'placement_unavailable'
  | 'bridge_offline'
  | 'delivery_unavailable'
  | 'conversation_unavailable';

export interface MessageDelivery {
  state: MessageDeliveryState;
  reason: MessageDeliveryReason;
}

// The status of an MCP chains.message result (same states).
export type ChainMessageStatus = MessageDeliveryState;

// Reads the `delivery` of a send-message response; absent on older hubs.
export function messageDeliveryOf(response: unknown): MessageDelivery | undefined {
  const raw = (response as any)?.delivery ?? (response as any)?.data?.delivery;
  if (!raw || (raw.state !== MESSAGE_DELIVERY_ACCEPTED && raw.state !== MESSAGE_DELIVERY_PENDING)) return undefined;
  return { state: raw.state, reason: typeof raw.reason === 'string' ? raw.reason : '' } as MessageDelivery;
}

export function pendingMessageDeliveryNotice(response: unknown): string {
  const delivery = messageDeliveryOf(response);
  if (delivery?.state !== MESSAGE_DELIVERY_PENDING) return '';
  switch (delivery.reason) {
    case 'agent_starting': return 'Message saved. The agent is starting.';
    case 'agent_manually_stopped': return 'Message saved. Start the agent to deliver it.';
    case 'bridge_offline': return 'Message saved. Reconnect the assigned bridge to deliver it.';
    case 'provider_unavailable': return 'Message saved. The selected provider is unavailable.';
    case 'placement_unavailable': return 'Message saved. The selected setup is unavailable.';
    default: return 'Message saved. Delivery is pending.';
  }
}
