---
name: contracts-first
description: Use when changing APIs, schemas, wire formats, event stores, task/participant state, config, or CLI contracts.
heimdall_managed: true
---

# Contracts first
- Identify the durable contract before coding: request/response JSON, DB schema, event record, CLI flags, config keys, UI type, or wrapper bootstrap field.
- Update writers, readers, replay/apply paths, tests, and documentation together so old and new surfaces do not diverge.
- Fail closed on deprecated or unknown behavioral fields rather than silently accepting stale contract input.
- Prefer small compatibility adapters at boundaries over scattered string checks in business logic.
- Include contract search proof in completion evidence when removing a field or concept.
