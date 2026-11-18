package main

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_channel_send_does_not_seal :: proc(t: ^testing.T) {
	text := "Hello \"owner\"\nhttps://example.com/ 🦊"
	params, err := ctl_channel_params("send", []string{"--text", text})
	testing.expect_value(t, err, "")
	value: struct {text: string}
	testing.expect_value(t, json.unmarshal(transmute([]byte)params, &value, allocator = context.temp_allocator), nil)
	testing.expect_value(t, value.text, text)
	testing.expect(t, !strings.contains(params, "vault:v"))
	tmp, _ := os.temp_dir(context.temp_allocator)
	path := strings.concatenate({tmp, "/ham_ctl_a6_channel_text.txt"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, transmute([]byte)text), nil)
	defer os.remove(path)
	file_params, file_err := ctl_channel_params("send", []string{"--text-file", path})
	testing.expect_value(t, file_err, "")
	testing.expect_value(t, file_params, params)
}

@(test)
test_channel_verbs_build_params :: proc(t: ^testing.T) {
	tokens := command_tokens([]string{"ham-ctl", "--text", "history", "channel", "send"})
	defer delete(tokens)
	testing.expect_value(t, len(tokens), 2)
	if len(tokens) == 2 {
		testing.expect_value(t, tokens[0], "channel")
		testing.expect_value(t, tokens[1], "send")
	}
	for verb in ([]string{"read", "history"}) {
		for limit in ([]string{"1", "20", "50"}) {
			params, err := ctl_channel_params(verb, []string{"--limit", limit})
			testing.expect_value(t, err, "")
			testing.expect_value(t, params, strings.concatenate({`{"limit":`, limit, "}"}, context.temp_allocator))
		}
		params, err := ctl_channel_params(verb, nil)
		testing.expect_value(t, err, "")
		testing.expect_value(t, params, `{"limit":20}`)
		_, err = ctl_channel_params(verb, []string{"--limit", "0"})
		testing.expect(t, err != "")
		_, err = ctl_channel_params(verb, []string{"--limit", "invalid"})
		testing.expect(t, err != "")
	}
	_, err := ctl_channel_params("send", []string{"--text-file", "/nonexistent/a6.txt"})
	testing.expect_value(t, err, "cannot read --text-file")
	_, err = ctl_channel_params("send", []string{"--text", "hi", "--text-file", "file"})
	testing.expect(t, err != "")
}

@(test)
test_channel_help_text :: proc(t: ^testing.T) {
	for line in ([]string{
		"ham-ctl channel read [--limit N]        Read your owner's unanswered messages from one channel (marks them read).",
		"ham-ctl channel send --text <text>      Answer on the channel of the messages you read.",
		"ham-ctl channel send --text-file <path> Same, text read from a UTF-8 file.",
		"ham-ctl channel history [--limit N]     Recent messages on all channels in both directions, newest first.",
		"Only a bot instance may use these verbs. Telegram and WhatsApp messages can be read by the provider and your Ninjy hub.",

	}) {
		testing.expect(t, strings.contains(CHANNEL_HELP, line))
	}
}
