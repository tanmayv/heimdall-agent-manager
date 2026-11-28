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
