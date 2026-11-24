package main

import "core:encoding/json"
import "core:strings"

acp_option_has_value :: proc(options: json.Array, wanted: string) -> bool {
    for item in options {
        obj, ok := item.(json.Object); if !ok do continue
        if value, ok := obj["value"].(json.String); ok && string(value) == wanted do return true
        if group, ok := obj["options"].(json.Array); ok && acp_option_has_value(group, wanted) do return true
    }
    return false
}

// Returns the actual configId, never a hard-coded option name. A duplicate
// category is ambiguous even when only one of the duplicates offers the value.
acp_config_selection :: proc(raw, category, value: string, selected := false) -> (string, bool) {
    root, err := json.parse(raw)
    if err != nil do return "", false
    defer json.destroy_value(root)
    obj, ok := root.(json.Object); if !ok do return "", false
    options, valid := obj["configOptions"].(json.Array); if !valid do return "", false
    count := 0
    id := ""
    matches := false
    for item in options {
        option, ok := item.(json.Object); if !ok do continue
        cat, _ := option["category"].(json.String); if string(cat) != category do continue
        count += 1
        kind, _ := option["type"].(json.String)
        name, _ := option["id"].(json.String)
        values, valid := option["options"].(json.Array)
        current, _ := option["currentValue"].(json.String)
        matches = kind == "select" && name != "" && valid && acp_option_has_value(values, value) && (!selected || string(current) == value)
        id = string(name)
    }
    if count != 1 || !matches do return "", false
    return strings.clone(id), true
}

acp_bootstrap_communication :: "Messages and answers arrive in session prompts. Your natural assistant text reaches user chat automatically. Use `./bin/ham-ctl` for task, lease, artifact, shell, memory, agent-to-agent communication, and structured questions/actions. Do not echo ordinary answers with chat send."

acp_bootstrap_original_communication :: "Messages from the user arrive through Heimdall, NOT your terminal. Read them with\n`./bin/ham-ctl chat read`; ALWAYS reply with\n`./bin/ham-ctl chat send --to user --body \"<your reply>\"`. Text you print to\nthe terminal is never delivered to the user. Load the `heimdall-ctl-communication` skill\nfor the full messaging workflow (agent-to-agent messages)."

bridge_bootstrap_acp_instructions :: proc(body: string) -> string {
    // replace_all returns `body` itself when nothing matched; the caller owns it.
    rendered, allocated := strings.replace_all(body, acp_bootstrap_original_communication, acp_bootstrap_communication)
    defer if allocated do delete(rendered)
    // This marker identifies the exact locally generated bootstrap used by the
    // conservative embedded-resource fallback for adapter 0.108.0.
    return strings.concatenate({rendered, "\n\n<!-- heimdall-acp-bootstrap-v1 -->\n", acp_bootstrap_communication, "\n"})
}
