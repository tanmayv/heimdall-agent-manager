UPDATE memories
SET body = replace(
  replace(
    body,
    'Reading user messages: when notified about a new message, run `./.heimdall/bin/ham-ctl agent chat read` before responding. Treat chat messages from the user as authoritative task guidance.',
    'Reading inbound messages: when notified about a new message, run `./.heimdall/bin/ham-ctl agent chat read` before responding. This fetches the agent-visible conversation transcript, including `user_to_agent` messages from the user and `agent_to_agent` messages from other agents. Treat chat messages from the user as authoritative task guidance.'
  ),
  'Reading user messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. Treat chat messages from the user as authoritative task guidance.',
  'Reading inbound messages: when notified about a new message, run ./.heimdall/bin/ham-ctl agent chat read before responding. This fetches the agent-visible conversation transcript, including user_to_agent messages from the user and agent_to_agent messages from other agents. Treat chat messages from the user as authoritative task guidance.'
),
updated_at = '2026-07-28T00:25:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication';
