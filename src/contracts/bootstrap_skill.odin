package contracts

// Dynamic_Skill_Blob is the content-addressed payload for memory skills.
// Metadata stays structured (and sealed) until the trusted bridge decrypts each
// field and serializes SKILL.md. Static skill blobs remain literal Markdown.
// All bootstrap writers, including legacy content responses, accept this shape.
BRIDGE_FEATURE_DYNAMIC_SKILL_V2 :: "dynamic_skill_v2"

DYNAMIC_SKILL_FORMAT :: "heimdall.dynamic-skill.v1"

Dynamic_Skill_Blob :: struct {
    format: string,
    memory_id: string,
    name: string,
    title: string,
    description: string,
    body: string,
}
