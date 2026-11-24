package actions

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import nats "odin_test:lib/nats"
import schedule "odin_test:lib/schedule"

schedule_kind := Trigger_Kind{kind="schedule",compile=schedule_compile,on_change=schedule_on_change,event_key=schedule_event_key,guard=schedule_guard}

schedule_time :: proc(value: string) -> (i64,bool) {
	parsed,consumed:=time.rfc3339_to_time_utc(value)
	if consumed!=len(value) || consumed==0 do return 0,false
	return time.to_unix_nanoseconds(parsed)/1_000_000,true
}
schedule_compile :: proc(owner, action_id, trigger_id: string, config: json.Object, allocator: mem.Allocator) -> (Match_Spec,domain.Domain_Error) {
	if !config_keys_valid(config,{"mode","cron_expr","timezone","interval_s","run_at","blackout_dates","active_from","active_until"}) do return {},detail_error("invalid_config")
	if !nats.subject_token(owner) || !nats.subject_token(action_id) || !nats.subject_token(trigger_id) do return {},detail_error("invalid_subject_token")
	mode,mode_ok:=config_string(config,"mode")
	if !mode_ok do return {},detail_error("invalid_schedule_mode")
	zone,zone_ok:=config_string(config,"timezone","UTC")
	if !zone_ok || !schedule.timezone_valid(zone) do return {},detail_error("invalid_timezone")
	// Type-check optional mode-specific fields even when another mode is selected.
	string_keys:=[]string{"cron_expr","run_at","active_from","active_until"}
	for key in string_keys {
		if _,ok:=config_string(config,key); !ok do return {},detail_error("invalid_config")
	}
	if raw,present:=config["interval_s"]; present {
		if _,ok:=raw.(json.Integer); !ok do return {},detail_error("invalid_interval")
	}
	switch mode {
	case "cron":
		expr,_:=config_string(config,"cron_expr")
		if _,ok:=schedule.parse_cron(expr); !ok do return {},detail_error("invalid_cron")
		text,ok:=schedule.nats_cron(expr,allocator)
		delete(text,allocator)
		if !ok do return {},detail_error("invalid_cron")
	case "interval":
		seconds,ok:=config["interval_s"].(json.Integer)
		if !ok || seconds<60 || seconds>31536000 do return {},detail_error("invalid_interval")
	case "once":
		value,_:=config_string(config,"run_at")
		if _,ok:=schedule_time(value); !ok do return {},detail_error("invalid_run_at")
	case: return {},detail_error("invalid_schedule_mode")
	}
	from,_:=config_string(config,"active_from")
	until,_:=config_string(config,"active_until")
	from_ms,until_ms:i64
	if from!="" {
		ok:bool
		from_ms,ok=schedule_time(from)
		if !ok do return {},detail_error("invalid_active_window")
	}
	if until!="" {
		ok:bool
		until_ms,ok=schedule_time(until)
		if !ok do return {},detail_error("invalid_active_window")
	}
	if from!="" && until!="" && from_ms>=until_ms do return {},detail_error("invalid_active_window")
	if raw,present:=config["blackout_dates"]; present {
		dates,ok:=raw.(json.Array)
		if !ok || len(dates)>366 do return {},detail_error("invalid_blackout_dates")
		for date in dates {
			text,string_ok:=date.(string)
			if !string_ok || len(text)!=10 do return {},detail_error("invalid_blackout_dates")
			value:=fmt.tprintf("%sT00:00:00Z",text)
			ms,time_ok:=schedule_time(value)
			if !time_ok || platform.format_rfc3339_utc(time.unix(ms/1000,(ms%1000)*1_000_000))!=value do return {},detail_error("invalid_blackout_dates")
		}
	}
	return {event_type=strings.clone("schedule.fired",allocator),subject_filter=strings.clone(fmt.tprintf("ev.%s.sched.%s",owner,trigger_id),allocator),data_filter_json=strings.clone("{}",allocator)},{}
}

schedule_event_key :: proc(msg: Event_View, allocator: mem.Allocator) -> string {
	next:=msg.schedule_next
	if next=="" || next=="purge" do next="once"
	return strings.clone(fmt.tprintf("%s:%s",msg.trigger_rev,next),allocator)
}
schedule_guard :: proc(t: domain.Action_Trigger, msg: Event_View) -> (run: bool, reason: string, retire: bool) {
	if msg.trigger_rev!=fmt.tprintf("%d",t.rev) do return false,"stale_rev",false
	value:json.Value
	if json.unmarshal(transmute([]u8)t.config_json,&value,allocator=context.temp_allocator)!=nil do return false,"outside_window",false
	defer json.destroy_value(value,allocator=context.temp_allocator)
	config,_:=value.(json.Object)
	mode,_:=config_string(config,"mode")
	retire=mode=="once"
	from,_:=config_string(config,"active_from")
	if from!="" {
		ms,_:=schedule_time(from)
		if msg.stream_time_ms<ms do return false,"outside_window",false
	}
	until,_:=config_string(config,"active_until")
	if until!="" {
		ms,_:=schedule_time(until)
		if msg.stream_time_ms>ms do return false,"outside_window",true
	}
	zone,_:=config_string(config,"timezone","UTC")
	year,month,day,ok:=schedule.local_date(msg.stream_time_ms,zone)
	if ok {
		date:=fmt.tprintf("%04d-%02d-%02d",year,month,day)
		dates,_:=config["blackout_dates"].(json.Array)
		for item in dates {
			if text,string_ok:=item.(string); string_ok && text==date do return false,"blackout",retire
		}
	}
	return true,"",retire
}

