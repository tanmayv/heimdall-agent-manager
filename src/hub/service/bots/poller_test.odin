package bots

import "base:runtime"
import "core:mem/virtual"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import channel "odin_test:hub/service/channel"
import httpc "odin_test:lib/httpc"

Runtime_Test_Experiments :: struct {enabled: int, fail: bool}
runtime_test_count :: proc(ctx: rawptr, key: string) -> (int, domain.Domain_Error) {
	e := (^Runtime_Test_Experiments)(ctx)
	if e.fail do return 0, domain.domain_error(.Internal_Error, "test error")
	if key != "bots" do return 0, domain.domain_error(.Internal_Error, "wrong key")
	return e.enabled, {}
}
runtime_test_identity :: proc(ctx: rawptr) -> (channel.Identity, channel.Channel_Error) { return {}, {} }
runtime_test_poll :: proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> ([]channel.Inbound, string, channel.Channel_Error) {
	for !sync.atomic_load(cancel) do time.sleep(time.Millisecond)
	return nil, "", {kind = .Aborted}
}

@(test)
test_poller_not_started_when_experiment_off_for_all :: proc(t: ^testing.T) {
	exp := Runtime_Test_Experiments{}
	exps := iface.Experiment_Repository{ctx = &exp, count_enabled = runtime_test_count}
	adapter := channel.Channel_Adapter{identity = runtime_test_identity, poll = runtime_test_poll}
	s := Bots_Service{experiments = &exps, adapter = &adapter}
	rt := Bots_Runtime{service = &s, telegram_bot_token = "TEST:FAKE"}
	defer bots_runtime_stop(&rt)
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.poller_running && !rt.supervisor_running && rt.poller == nil && rt.supervisor == nil)
}

@(test)
test_poller_not_started_without_token :: proc(t: ^testing.T) {
	exp := Runtime_Test_Experiments{enabled = 1}
	exps := iface.Experiment_Repository{ctx = &exp, count_enabled = runtime_test_count}
	s := Bots_Service{experiments = &exps}
	rt := Bots_Runtime{service = &s}
	defer bots_runtime_stop(&rt)
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.poller_running && rt.poller == nil)
	testing.expect(t, rt.supervisor_running && rt.supervisor != nil)
}

// Exercise the HTTP callback allocation context: thread records must survive
// destruction of the request arena that called reconcile.
runtime_test_reconcile_in_scratch :: proc(rt: ^Bots_Runtime) {
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil do return
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)
	context.temp_allocator = context.allocator
	bots_runtime_reconcile(rt)
}

@(test)
test_runtime_reconcile_starts_and_stops :: proc(t: ^testing.T) {
	exp := Runtime_Test_Experiments{enabled = 1}
	exps := iface.Experiment_Repository{ctx = &exp, count_enabled = runtime_test_count}
	adapter := channel.Channel_Adapter{identity = runtime_test_identity, poll = runtime_test_poll}
	s := Bots_Service{experiments = &exps, adapter = &adapter}
	rt := Bots_Runtime{service = &s, telegram_bot_token = "TEST:FAKE"}
	defer bots_runtime_stop(&rt)
	runtime_test_reconcile_in_scratch(&rt)
	testing.expect(t, rt.poller_running && rt.supervisor_running)
	testing.expect(t, rt.poller.creation_allocator.procedure == runtime.heap_allocator().procedure)
	poller, supervisor := rt.poller, rt.supervisor
	bots_runtime_reconcile(&rt)
	testing.expect(t, rt.poller == poller && rt.supervisor == supervisor, "idempotent start")
	rt.telegram_bot_token = ""
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.poller_running && rt.supervisor_running)
	rt.telegram_bot_token = "TEST:FAKE"
	bots_runtime_reconcile(&rt)
	testing.expect(t, rt.poller_running && rt.supervisor_running)
	exp.enabled = 0
	bots_on_experiment_changed(&rt,"alice","other",false)
	testing.expect(t, rt.poller_running && rt.supervisor_running, "other keys ignored")
	bots_on_experiment_changed(&rt,"alice","bots",false)
	testing.expect(t, !rt.poller_running && !rt.supervisor_running && rt.poller == nil && rt.supervisor == nil)
	exp.enabled = 1
	bots_on_experiment_changed(&rt,"alice","bots",true)
	testing.expect(t, rt.poller_running && rt.supervisor_running, "restart after stop")
	exp.fail = true
	bots_runtime_reconcile(&rt)
	testing.expect(t, !rt.poller_running && !rt.supervisor_running, "count failure fails closed")
}

Poller_Test_Repo :: struct {mutex: sync.Mutex, calls: int, cursor: string, rows_seen: int}
poller_test_cursor :: proc(ctx: rawptr, provider: string) -> (string, bool, domain.Domain_Error) {
	r := (^Poller_Test_Repo)(ctx)
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	return strings.clone(r.cursor), true, {}
}
poller_test_store :: proc(ctx: rawptr, provider: string, rows: []domain.Channel_Message, next_cursor, now: string) -> ([]string, domain.Domain_Error) {
	r := (^Poller_Test_Repo)(ctx)
	sync.mutex_lock(&r.mutex); defer sync.mutex_unlock(&r.mutex)
	r.calls += 1; r.rows_seen += len(rows)
	if r.calls == 1 do return nil, domain.domain_error(.Internal_Error, "rollback double")
	if next_cursor != "3" do return nil, domain.domain_error(.Internal_Error, "unexpected next cursor")
	r.cursor = "3"
	return nil, {}
}

@(test)
test_poller_does_not_advance_offset_before_commit :: proc(t: ^testing.T) {
	ok, message := httpc.init()
	if !testing.expect(t, ok, message) do return
	ready := fmt.aprintf("%s/.cache/heimdall-tests/poller-%d-%d.ready", os.get_env("HOME",context.temp_allocator),os.get_pid(),time.tick_now())
	defer delete(ready); defer os.remove(ready)
	child, child_err := os.process_start({command = {"node","tools/fake_telegram/server.mjs","--port","0","--ready-file",ready}})
	if !testing.expect(t, child_err == nil) do return
	defer { _ = os.process_kill(child); _, _ = os.process_wait(child) }
	base_text := ""
	for _ in 0..<250 {
		bytes, read_err := os.read_entire_file(ready, context.allocator)
		if read_err == nil { base_text = string(bytes); break }
		time.sleep(20*time.Millisecond)
	}
	defer delete(base_text)
	if !testing.expect(t, base_text != "", "fake Telegram ready") do return
	base, _ := httpc.parse_url(base_text)
	for i in 0..<2 {
		response, err := httpc.send({method = .POST, url = base, path = {"_control","inject"}, body = httpc.json_body(struct{chat_id,from_id:int,text:string}{111,222,fmt.tprintf("message %d",i)})})
		testing.expect(t, err == .None && response.status == 200)
		httpc.response_destroy(&response)
	}
	telegram := channel.Telegram_Adapter{token = "TEST:FAKE", api_base = base_text}
	defer channel.telegram_destroy(&telegram)
	adapter := channel.telegram_adapter(&telegram)
	exp := Runtime_Test_Experiments{enabled = 1}
	exps := iface.Experiment_Repository{ctx = &exp, count_enabled = runtime_test_count}
	repo_state := Poller_Test_Repo{cursor = "1"}
	repo := iface.Bot_Repository{ctx = &repo_state, cursor_get = poller_test_cursor, inbound_store_batch = poller_test_store}
	service := Bots_Service{repo = &repo, experiments = &exps, adapter = &adapter}
	rt := Bots_Runtime{service = &service, telegram_bot_token = "TEST:FAKE"}
	defer bots_runtime_stop(&rt)
	bots_runtime_reconcile(&rt)
	offsets: []int
	for _ in 0..<100 {
		response, err := httpc.send({url = base, path = {"_control","offsets"}})
		_ = json.unmarshal(response.body,&offsets, allocator = context.temp_allocator)
		httpc.response_destroy(&response)
		if err == .None && len(offsets) >= 3 do break
		time.sleep(100*time.Millisecond)
	}
	if testing.expect(t, len(offsets) >= 3, "three polls observed") {
		first, second, third := offsets[0], offsets[1], offsets[2]
		testing.expect(t, first == 1 && second == 1 && third == 3, "failed store re-polls old offset before successful commit")
	}
	bots_runtime_stop(&rt)
	sync.mutex_lock(&repo_state.mutex)
	testing.expect(t, repo_state.calls == 2 && repo_state.rows_seen == 0 && repo_state.cursor == "3")
	sync.mutex_unlock(&repo_state.mutex)
}
