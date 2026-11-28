package contracts

import "core:slice"

// PTY delivery modes as data (CONTRACT-17).
//
// A PTY agent runtime types inputs into the provider CLI's terminal. The three
// delivery modes are fixed step lists; only their key data varies:
//   queue    = type, submit                                   (at a trusted idle)
//   send_now = interrupt keys, wait for idle (<= idle_wait_ms), type, submit
//   steer    = interrupt keys, type, submit                   (no idle wait)
//
// Key data defaults here, a provider descriptor overrides it (its pty_delivery),
// and a provider profile overrides that (Provider_Profile_Config.pty_delivery).
// Each layer is a Pty_Delivery_Spec whose zero values inherit.

Pty_Paste_Mode :: enum u8 {
	Raw,       // the body is typed as is
	Bracketed, // the body is wrapped in bracketed-paste markers
}

// Pty_Delivery_Spec is one override layer. Empty lists, "" flags and 0 delays
// inherit; a negative delay means none (0 ms). Flags are "on" or "off".
Pty_Delivery_Spec :: struct {
	interrupt_keys:         []string `json:"interrupt_keys"`,
	submit_keys:            []string `json:"submit_keys"`,
	second_submit:          string `json:"second_submit"`,
	paste_mode:             string `json:"paste_mode"`, // "raw" | "bracketed"
	sanitize:               string `json:"sanitize"`,
	can_steer:              string `json:"can_steer"`,
	key_delay_ms:           int `json:"key_delay_ms"`,
	interrupt_settle_ms:    int `json:"interrupt_settle_ms"`,
	submit_delay_ms:        int `json:"submit_delay_ms"`,
	second_submit_delay_ms: int `json:"second_submit_delay_ms"`,
	idle_wait_ms:           int `json:"idle_wait_ms"`,
}

// Pty_Delivery is the resolved key data. Key lists are borrowed from the layer
// that set them.
Pty_Delivery :: struct {
	interrupt_keys:         []string,
	submit_keys:            []string,
	// Press the submit keys a second time, for TUIs that take the first Enter
	// of a paste as a newline.
	second_submit:          bool,
	paste_mode:             Pty_Paste_Mode,
	// Drop ESC (which would interrupt the turn) and fold CR/LF (which would
	// submit early) in the typed body.
	sanitize:               bool,
	// The CLI accepts typed input into a running turn (explicit steer).
	can_steer:              bool,
	key_delay_ms:           int,
	interrupt_settle_ms:    int,
	submit_delay_ms:        int,
	second_submit_delay_ms: int,
	idle_wait_ms:           int,
}

// Key names a delivery sequence may use (the bridge maps them to PTY keys).
PTY_DELIVERY_KEYS :: [?]string{"esc", "enter", "ctrl_c", "tab", "ctrl_d"}
PTY_DELIVERY_MAX_KEYS :: 8
PTY_DELIVERY_MAX_DELAY_MS :: 60_000

@(private)
pty_delivery_default_interrupt := [?]string{"esc"}
@(private)
pty_delivery_default_submit := [?]string{"enter"}

// pty_delivery_default is the key data every provider starts from: Esc
// interrupts, Enter submits (twice, 150 ms apart, after a 300 ms settle), raw
// sanitized paste, no steering, and send now waits up to 5 s for idle.
pty_delivery_default :: proc() -> Pty_Delivery {
	return Pty_Delivery{
		interrupt_keys = pty_delivery_default_interrupt[:], submit_keys = pty_delivery_default_submit[:],
		second_submit = true, paste_mode = .Raw, sanitize = true, can_steer = false,
		key_delay_ms = 50, interrupt_settle_ms = 300, submit_delay_ms = 300, second_submit_delay_ms = 150, idle_wait_ms = 5000,
	}
}

pty_delivery_key_valid :: proc(name: string) -> bool {
	keys := PTY_DELIVERY_KEYS
	return slice.contains(keys[:], name)
}

pty_delivery_flag_valid :: proc(flag: string) -> bool {
	return flag == "" || flag == "on" || flag == "off"
}

// pty_delivery_spec_valid checks one override layer.
pty_delivery_spec_valid :: proc(s: Pty_Delivery_Spec) -> bool {
	if len(s.interrupt_keys) > PTY_DELIVERY_MAX_KEYS || len(s.submit_keys) > PTY_DELIVERY_MAX_KEYS do return false
	for k in s.interrupt_keys do if !pty_delivery_key_valid(k) do return false
	for k in s.submit_keys do if !pty_delivery_key_valid(k) do return false
	if !pty_delivery_flag_valid(s.second_submit) || !pty_delivery_flag_valid(s.sanitize) || !pty_delivery_flag_valid(s.can_steer) do return false
	if s.paste_mode != "" && s.paste_mode != "raw" && s.paste_mode != "bracketed" do return false
	for d in ([]int{s.key_delay_ms, s.interrupt_settle_ms, s.submit_delay_ms, s.second_submit_delay_ms, s.idle_wait_ms}) {
		if d > PTY_DELIVERY_MAX_DELAY_MS do return false
	}
	return true
}

@(private)
pty_delivery_flag :: proc(target: ^bool, flag: string) {
	if flag == "on" do target^ = true
	if flag == "off" do target^ = false
}

@(private)
pty_delivery_delay :: proc(target: ^int, value: int) {
	if value > 0 do target^ = min(value, PTY_DELIVERY_MAX_DELAY_MS)
	if value < 0 do target^ = 0
}

// pty_delivery_resolve applies override layers, lowest precedence first, over
// the defaults. An invalid layer is skipped whole, so a bad override never
// produces a half-applied key sequence.
pty_delivery_resolve :: proc(layers: ..Pty_Delivery_Spec) -> Pty_Delivery {
	out := pty_delivery_default()
	for s in layers {
		if !pty_delivery_spec_valid(s) do continue
		if len(s.interrupt_keys) > 0 do out.interrupt_keys = s.interrupt_keys
		if len(s.submit_keys) > 0 do out.submit_keys = s.submit_keys
		pty_delivery_flag(&out.second_submit, s.second_submit)
		pty_delivery_flag(&out.sanitize, s.sanitize)
		pty_delivery_flag(&out.can_steer, s.can_steer)
		if s.paste_mode == "raw" do out.paste_mode = .Raw
		if s.paste_mode == "bracketed" do out.paste_mode = .Bracketed
		pty_delivery_delay(&out.key_delay_ms, s.key_delay_ms)
		pty_delivery_delay(&out.interrupt_settle_ms, s.interrupt_settle_ms)
		pty_delivery_delay(&out.submit_delay_ms, s.submit_delay_ms)
		pty_delivery_delay(&out.second_submit_delay_ms, s.second_submit_delay_ms)
		pty_delivery_delay(&out.idle_wait_ms, s.idle_wait_ms)
	}
	return out
}
