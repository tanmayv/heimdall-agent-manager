---
name: artifact-sharing
description: Use when deciding how to share a document, file path, or markdown with the user.
heimdall_managed: true
---

# Artifact sharing
- Never share md file paths directly with the user in chat.
- Consistently share markdown files as a ham-ctl artifact.
- Create the artifact using the reference ham-ctl command: `ham-ctl artifacts create --token <token> --file <path> --name <name> --kind markdown`
