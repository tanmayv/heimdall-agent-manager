package main

// G1: the standard agent skills a remote (executor-launched) agent gets, from
// this Bridge's own build. They are public product docs, identical on every
// Bridge, and too large for the owner's 32 KiB bootstrap document; an owner
// skill of the same name takes precedence.
Bridge_Executor_Skill :: struct {name,content:string}
BRIDGE_EXECUTOR_SKILLS := [?]Bridge_Executor_Skill{
    {"worker-task-management",#load("../prompts/skills/worker-task-management/SKILL.md",string)},
    {"heimdall-ctl-communication",#load("../prompts/skills/heimdall-ctl-communication/SKILL.md",string)},
    {"ham-ctl-reference",#load("../prompts/skills/ham-ctl-reference/SKILL.md",string)},
    {"memory-management-workflow",#load("../prompts/skills/memory-management-workflow/SKILL.md",string)},
    {"search-command",#load("../prompts/skills/search-command/SKILL.md",string)},
    {"artifact-authoring",#load("../prompts/skills/artifact-authoring/SKILL.md",string)},
}
