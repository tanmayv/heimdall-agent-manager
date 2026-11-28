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

// Profile inventories use the same category and exact value IDs as selection.
acp_model_options_append :: proc(values: json.Array, models: ^[dynamic]Bridge_Discovered_Model, depth := 0) -> bool {
    if depth > 8 do return false
    for item in values {
        obj, ok := item.(json.Object); if !ok do return false
        if nested, present := obj["options"]; present {
            group, ok := nested.(json.Array); if !ok || !acp_model_options_append(group, models, depth + 1) do return false
        } else {
            value, ok := obj["value"].(json.String); if !ok do return false
            label, _ := obj["name"].(json.String)
            if !bridge_models_append(models, string(value), string(label) if label != "" else string(value), "") do return false
        }
    }
    return true
}

acp_model_options :: proc(result: json.Object, category: string, models: ^[dynamic]Bridge_Discovered_Model) -> string {
    raw, present := result["configOptions"]
    if !present do return "unsupported"
    options, ok := raw.(json.Array); if !ok do return "invalid_response"
    count := 0
    for item in options {
        option, ok := item.(json.Object); if !ok do return "invalid_response"
        cat, _ := option["category"].(json.String); if string(cat) != category do continue
        count += 1
        kind, _ := option["type"].(json.String)
        id, _ := option["id"].(json.String)
        choices, valid := option["options"].(json.Array)
        if count != 1 || kind != "select" || id == "" || !valid ||
           !acp_model_options_append(choices, models) { return "invalid_response" }
    }
    return "success" if count == 1 && len(models) > 0 else "unsupported"
}
