package domain

CARD_STATUS_PENDING   :: "pending"
CARD_STATUS_ACCEPTED  :: "accepted"
CARD_STATUS_REJECTED  :: "rejected"
CARD_STATUS_SNOOZED   :: "snoozed"
CARD_STATUS_DISCARDED :: "discarded"

CARD_SCOPE_MEMORY  :: "memory"
CARD_SCOPE_PROJECT :: "project"
CARD_SCOPE_AGENT   :: "agent"
CARD_SCOPE_TASK    :: "task"

CARD_PROVIDER_TASK_VALIDATION :: "task_validation"
CARD_PROVIDER_MEMORY_PROPOSAL :: "memory_proposal"
CARD_PROVIDER_CURATOR_LLM     :: "curator_llm"

Card :: struct {
	card_id:          Card_ID,
	owner_user_id:    User_ID,
	project_id:       Project_ID,
	title:            string,
	rationale:        string,
	scope:            string,
	provider:         string,
	confidence:       f32,
	source_refs_json: string,
	status:           string,
	operations_json:  string,
	guard_json:       string,
	snooze_until:     string,
	ttl_at:           string,
	created_at:       string,
	updated_at:       string,
}
