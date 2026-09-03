---
name: heimdall-ctl-communication
description: Use Heimdall CLI for agent startup, chat communication, task coordination, and concise status reporting. Load when communicating through Heimdall or reacting to message notifications.
---

# Heimdall CLI communication basics

Use the managed Heimdall CLI wrapper from the agent run directory for all Heimdall communication: `./.heimdall/bin/ham-ctl`.

Startup: after you are fully ready, report readiness with `./.heimdall/bin/ham-ctl agent start-success`.

Read inbound messages with `./.heimdall/bin/ham-ctl agent chat read` and reply to the user with `./.heimdall/bin/ham-ctl agent chat send --body "..."`. Keep replies concise and include blockers, concrete results, and next steps.