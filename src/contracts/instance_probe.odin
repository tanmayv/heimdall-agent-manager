package contracts

INSTANCE_PROBE_COMMAND :: "instance.probe"
INSTANCE_PROBE_LAUNCH_ABSENCE :: "launch_absence"

// for_launch optionally enables the Bridge's launch-only absence check when
// a complete roster omits the instance and no prior process identity is recorded.
// This is not an exit receipt. Only launch admission may use such a response,
// and only when run_count and launch_epoch match the generation queried.
Instance_Probe_Command :: struct {
	type:              string `json:"type"`,
	command_id:        string `json:"command_id"`,
	agent_instance_id: string `json:"agent_instance_id"`,
	for_launch:        bool   `json:"for_launch,omitempty"`,
}
