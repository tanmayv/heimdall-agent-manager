package contracts

BRIDGE_FEATURE_START_AGENT_V1 :: "start_agent_v1"
START_AGENT_FRAME :: "start_agent"
START_DELIVER_LAUNCH :: "launch"
START_DELIVER_NUDGE :: "nudge"

// POST /agent-instances/:id/restart. Manual restart may omit the fence (-1).
// Context rollover sends its original launch generation; a fenced restart
// requires that generation to remain live and have no committed stop intent.
Restart_Instance_Input :: struct {
	expected_run_count: int,
}
