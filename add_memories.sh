#!/bin/bash
declare -A BODIES
declare -A TITLES

TITLES["scholar-agent@oncall"]="On-Call Context Gathering"
BODIES["scholar-agent@oncall"]="When a page fires, immediately ingest the specific context. Read the firing alert payload. Fetch the linked playbook. Search the issue tracker for past bugs with this exact stack trace or alert name. Read the prev-oncall notes from the last shift. Summarize the historical context of this alert."

TITLES["analyst-agent@oncall"]="On-Call Diagnosis & Confidence"
BODIES["analyst-agent@oncall"]="Interrogate the data to find the root cause and determine confidence. Compare the current system state (logs, metrics) against the Scholar's historical context. What is the most likely root cause? Score your confidence as High, Medium, or Low. If High, point to the exact past bug that confirms this."

TITLES["architect-agent@oncall"]="On-Call Mitigation Planning"
BODIES["architect-agent@oncall"]="Define what to do without actually doing it yet. Draft a step-by-step mitigation plan based on the playbook's recommended actions for this specific failure mode. Do not write the actual scripts or commands yet. Just list the operational steps and the expected blast radius. Wait for Orchestrator approval."

TITLES["producer-agent@oncall"]="On-Call Execution"
BODIES["producer-agent@oncall"]="Safely generate the specific commands or code to execute the approved plan. Once the mitigation plan is approved by the Orchestrator, generate the exact CLI commands, config changes, or scripts required (e.g., using standard internal tooling syntax like f1-sql or stubby)."

TITLES["advisor-agent@oncall"]="On-Call Verification & Post-Mortem"
BODIES["advisor-agent@oncall"]="Ensure the fix actually worked, update documentation, and handle handoffs. Act as a skeptical Site Reliability Engineer. Review the metrics from the last 15 minutes since mitigation. Draft the resolution comment for the bug ticket and suggest an update to the playbook."

for AGENT in "scholar-agent@oncall" "analyst-agent@oncall" "architect-agent@oncall" "producer-agent@oncall" "advisor-agent@oncall"; do
    START_OUTPUT=$(ham-ctl agents start $AGENT 2>/dev/null)
    AGENT_TOKEN=$(echo "$START_OUTPUT" | jq -r '.agent_token')
    
    if [[ -n "$AGENT_TOKEN" && "$AGENT_TOKEN" != "null" ]]; then
        echo "Got token for $AGENT: $AGENT_TOKEN"
        OUTPUT=$(ham-ctl memory propose new --token $AGENT_TOKEN --agent $AGENT --type expertise --title "${TITLES[$AGENT]}" --body "${BODIES[$AGENT]}")
        PROP_ID=$(echo "$OUTPUT" | jq -r '.proposal_id')
        if [[ -n "$PROP_ID" && "$PROP_ID" != "null" ]]; then
            ham-ctl memory decide --token $AGENT_TOKEN --proposal-id $PROP_ID --decision approve
            echo "Approved memory for $AGENT"
        else
            echo "Failed to propose memory for $AGENT: $OUTPUT"
        fi
    fi
done
