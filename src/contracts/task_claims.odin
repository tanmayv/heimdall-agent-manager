package contracts

// instance_id is a coordinator-selected beneficiary, never authentication.
Task_Claim_Request :: struct {
    task_id: string `json:"task_id"`,
    instance_id: string `json:"instance_id,omitempty"`,
    reason: string `json:"reason,omitempty"`,
    request_id: string `json:"request_id,omitempty"`,
    expected_generation: i64 `json:"expected_generation,omitempty"`,
    vcs_base: string `json:"vcs_base,omitempty"`,
}
Task_Cancel_Request :: struct {
    reason: string `json:"reason"`,
    request_id: string `json:"request_id"`,
    expected_generation: i64 `json:"expected_generation,omitempty"`,
}
