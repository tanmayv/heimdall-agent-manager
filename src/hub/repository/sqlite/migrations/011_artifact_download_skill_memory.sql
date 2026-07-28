UPDATE memories
SET body = replace(
  body,
  'Read artifact bodies with `./.heimdall/bin/ham-ctl agent artifacts read --artifact-id <artifact_id>` (aliases: `content` or `get`).',
  'Read artifact bodies with `./.heimdall/bin/ham-ctl agent artifacts read --artifact-id <artifact_id>` (aliases: `content` or `get`). To materialize an artifact as a local file, run `./.heimdall/bin/ham-ctl agent artifacts download --artifact-id <artifact_id> --dir <directory>`; it writes a random filename with the inferred extension and returns the filename/path.'
),
updated_at = '2026-07-28T22:45:00Z'
WHERE memory_id = 'mem_system_heimdall_ctl_communication'
  AND instr(body, 'artifacts download --artifact-id') = 0;
