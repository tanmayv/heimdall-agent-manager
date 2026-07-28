UPDATE memories
SET body = body || '

Artifacts: use artifacts for large logs, screenshots, diffs, generated files, or any output too large/noisy for chat. Create artifacts from an agent run with `./.heimdall/bin/ham-ctl agent artifacts create --name "<name>" --kind markdown --content "..."`, `--file <path>`, or `--stdin`; use `--content-type <mime>` when useful. List available artifacts with `./.heimdall/bin/ham-ctl agent artifacts list`. Inspect metadata with `./.heimdall/bin/ham-ctl agent artifacts show --artifact-id <artifact_id>` or include content with `--with-content`. Read artifact bodies with `./.heimdall/bin/ham-ctl agent artifacts read --artifact-id <artifact_id>` (aliases: `content` or `get`). When reporting work, summarize briefly in chat and include the `artifact_id` / `artifact://<artifact_id>` reference rather than pasting large content inline.',
    updated_at = '2026-07-28T00:30:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication'
  AND instr(body, 'Artifacts: use artifacts for large logs') = 0;
