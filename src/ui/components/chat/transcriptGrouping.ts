import type { ChatMessage } from './types';

/**
 * Checks whether a message represents an agent start/restart system notice.
 */
export function isAgentStartMessage(message: ChatMessage): boolean {
  if (message.messageType === 'agent_start' || message.messageType === 'agent_start_clubbed') return true;
  if (message.messageType === 'system') return true;
  const body = (message.body || '').toLowerCase();
  return (
    body.includes('started') ||
    body.includes('ready') ||
    body.includes('restart') ||
    Boolean(message.metadata?.system_type === 'agent_start' || message.metadata?.system_type === 'startup')
  );
}

/**
 * Groups consecutive shell_run messages (length >= 2) into a clubbed group,
 * and groups consecutive agent start messages (length >= 2) into a clubbed start notice.
 * Filters out runs that are currently pinned above the composer.
 */
export function groupTranscriptMessages(
  messages: ChatMessage[],
  pinnedSessionIds: Set<string> = new Set(),
): ChatMessage[] {
  const unpinned = messages.filter((message) => {
    if (message.messageType !== 'shell_run') return true;
    const sessionId = String(message.metadata?.session_id || message.metadata?.sessionId || '');
    return !pinnedSessionIds.has(sessionId);
  });

  const result: ChatMessage[] = [];
  let i = 0;
  while (i < unpinned.length) {
    const msg = unpinned[i];

    // 1. Consecutive shell_run messages (length >= 2) -> REQ-CLUB-RUN-COMMANDS-13
    if (msg.messageType === 'shell_run') {
      let j = i;
      while (j < unpinned.length && unpinned[j].messageType === 'shell_run') {
        j++;
      }
      const runGroup = unpinned.slice(i, j);
      if (runGroup.length >= 2) {
        const firstRun = runGroup[0];
        const lastRun = runGroup[runGroup.length - 1];
        result.push({
          key: `clubbed_run_${firstRun.messageId}_${lastRun.messageId}`,
          messageId: `clubbed_run_${firstRun.messageId}`,
          body: '',
          isUser: false,
          createdUnixMs: firstRun.createdUnixMs,
          deliveredUnixMs: 0,
          readUnixMs: 0,
          deliveryFailedUnixMs: 0,
          deliveryError: '',
          sending: false,
          authorLabel: '',
          messageType: 'shell_run_group',
          messageStatus: 'complete',
          metadata: {
            clubbedRuns: runGroup,
            count: runGroup.length,
            startUnixMs: firstRun.createdUnixMs,
            endUnixMs: lastRun.createdUnixMs,
          },
        });
        i = j;
        continue;
      } else {
        result.push(msg);
        i++;
        continue;
      }
    }

    // 2. Consecutive agent start/restart system messages (length >= 2) -> REQ-SUBTLE-AGENT-START-14
    if (isAgentStartMessage(msg)) {
      let j = i;
      while (j < unpinned.length && isAgentStartMessage(unpinned[j])) {
        j++;
      }
      const startGroup = unpinned.slice(i, j);
      if (startGroup.length >= 2) {
        const firstStart = startGroup[0];
        const lastStart = startGroup[startGroup.length - 1];
        result.push({
          key: `clubbed_start_${firstStart.messageId}_${lastStart.messageId}`,
          messageId: `clubbed_start_${firstStart.messageId}`,
          body: `agent started ${startGroup.length} times`,
          isUser: false,
          createdUnixMs: firstStart.createdUnixMs,
          deliveredUnixMs: 0,
          readUnixMs: 0,
          deliveryFailedUnixMs: 0,
          deliveryError: '',
          sending: false,
          authorLabel: '',
          messageType: 'agent_start_clubbed',
          messageStatus: 'complete',
          metadata: {
            clubbedStarts: startGroup,
            count: startGroup.length,
            startUnixMs: firstStart.createdUnixMs,
            endUnixMs: lastStart.createdUnixMs,
          },
        });
        i = j;
        continue;
      } else {
        result.push(msg);
        i++;
        continue;
      }
    }

    // Any other message
    result.push(msg);
    i++;
  }

  return result;
}
