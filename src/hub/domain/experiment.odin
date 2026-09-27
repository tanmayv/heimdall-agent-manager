package domain

STREAMING_TERMINAL_PANE_EXPERIMENT_KEY :: "streaming_terminal_pane"

Experiment :: struct {
	owner_user_id: string,
	key:           string,
	enabled:       bool,
	updated_at:    string,
}
