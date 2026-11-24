package main
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import httpc "odin_test:lib/httpc"

// Delays use whole seconds; accept a bare count or s/m/h suffix.
ctl_action_delay :: proc(text: string) -> (i64, bool) {
 if text == "" do return 0, false
 multiplier: i64 = 1
 number := text
 switch text[len(text)-1] {
 case 's': number = text[:len(text)-1]
 case 'm': number = text[:len(text)-1]; multiplier = 60
 case 'h': number = text[:len(text)-1]; multiplier = 3600
 }
 n, ok := strconv.parse_i64(number)
 if !ok || n < 0 || n > 86400/multiplier do return 0, false
 return n*multiplier, true
}

ctl_action_object :: proc() -> json.Object {
	return make(json.Object, context.temp_allocator)
}

ctl_action_trigger :: proc(spec: string) -> (json.Value, bool) {
	config := ctl_action_object()
	trigger := ctl_action_object()
	colon := strings.index(spec, ":")
	if colon < 1 || colon == len(spec) - 1 do return nil, false
	form, value := spec[:colon], spec[colon + 1:]
	switch form {
	case "cron":
		expr, zone := value, "UTC"
		if at := strings.last_index(value, "@"); at >= 0 {
			expr, zone = value[:at], value[at + 1:]
		}
		if strings.trim_space(expr) == "" || zone == "" do return nil, false
		trigger["kind"] = json.String("schedule")
		config["mode"] = json.String("cron")
		config["cron_expr"] = json.String(expr)
		config["timezone"] = json.String(zone)
	case "every":
		seconds, ok := strconv.parse_i64(value)
		if !ok || seconds <= 0 do return nil, false
		trigger["kind"] = json.String("schedule")
		config["mode"] = json.String("interval")
		config["interval_s"] = json.Integer(seconds)
	case "at":
		trigger["kind"] = json.String("schedule")
		config["mode"] = json.String("once")
		config["run_at"] = json.String(value)
 case "event":
  parts:=strings.split(value,",",context.temp_allocator)
  if parts[0]=="" do return nil,false
  trigger["kind"]=json.String("event")
  config["event_type"]=json.String(parts[0])
  checks:=make(json.Array,0,len(parts)-1,context.temp_allocator)
  for pair in parts[1:] {
   check,ok:=ctl_automation_check(pair)
   if !ok do return nil,false
   append(&checks,check)
  }
  if len(checks)>0 {tree:=ctl_action_object();tree["all"]=checks;config["filter"]=tree}
	case:
		return nil, false
	}
	trigger["config"] = config
	return trigger, true
}

// Build without I/O so malformed syntax cannot send a partial request.
ctl_automation_request :: proc(tokens, args: []string) -> (Ctl_Request, bool) {
	action := pos(tokens, 0)
 if has_flag(args,"--enable") && (has_flag(args,"--disable") || has_flag(args,"--disabled")) do return {},false
	if action == "" || action == "list" {
		return {method = .GET, path = ctl_api("actions")}, true
	}
	id := pos(tokens, 1)
	switch action {
	case "show", "delete", "runs":
		if id == "" || strings.has_prefix(id, "--") do return {}, false
		switch action {
		case "show":
			return {method = .GET, path = ctl_api("actions", id)}, true
		case "delete":
			return {method = .DELETE, path = ctl_api("actions", id)}, true
		case "runs":
			query := ctl_query_make()
			for flag in ([]string{"--limit", "--before", "--before-id"}) {
				if has_flag(args, flag) {
					value := option_value(args, flag, "")
					if value == "" || strings.has_prefix(value, "--") do return {}, false
					if flag == "--limit" {
						n, ok := strconv.parse_int(value)
						if !ok || n < 1 || n > 200 do return {}, false
						ctl_query_add(&query, "limit", value)
					} else {
						key := "before"
						if flag == "--before-id" do key = "before_id"
						ctl_query_add(&query, key, value)
					}
				}
			}
			return {method = .GET, path = ctl_api("actions", id, "runs"), query = query[:]}, true
		}
	case "create", "update":
	case:
		return {}, false
	}
	if action == "update" && (id == "" || strings.has_prefix(id, "--")) do return {}, false
	body := ctl_action_object()
	target := ctl_action_object()
	rules := make([dynamic]json.Value, context.temp_allocator)
	triggers := make([dynamic]json.Value, context.temp_allocator)
	target_given, triggers_given := false, false
	target_count := 0
	for i := 0; i < len(args); i += 1 {
		flag := args[i]
		switch flag {
		case "--disabled", "--disable", "--enable":
 body["enabled"]=json.Boolean(flag=="--enable")
		case "--prompt", "--name", "--min-interval", "--agent-id", "--project", "--instance-strategy", "--rule", "--instance", "--bot", "--target", "--trigger", "--trigger-json", "--delay", "--filter", "--filter-file", "--entity":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "--") do return {}, false
			i += 1
			value := args[i]
			switch flag {
			case "--filter", "--filter-file", "--entity":
    if len(triggers)==0 do return {},false
    trigger,valid:=triggers[len(triggers)-1].(json.Object)
    kind,_:=trigger["kind"].(json.String)
    if !valid || kind!="event" do return {},false
    config,valid_config:=trigger["config"].(json.Object)
    if !valid_config do return {},false
    if flag=="--entity" {config["entity_id"]=json.String(value)} else {
     if _,exists:=config["filter"];exists do return {},false
     tree:json.Value
     if flag=="--filter-file" {
      data,err:=os.read_entire_file(value,context.temp_allocator)
      if err!=nil || json.unmarshal(data,&tree,allocator=context.temp_allocator)!=nil do return {},false
      if _,object:=tree.(json.Object);!object do return {},false
     } else {
      check,ok:=ctl_automation_check(value)
      if !ok do return {},false
      tree=check
     }
     config["filter"]=tree
    }
   case "--delay":
                if len(triggers) == 0 do return {}, false
                delay, valid := ctl_action_delay(value)
                if !valid do return {}, false
                trigger, valid_object := triggers[len(triggers)-1].(json.Object)
                if !valid_object do return {}, false
                trigger["delay_s"] = json.Integer(delay)
            case "--prompt":
				body["prompt_text"] = json.String(value)
			case "--name":
				body["name"] = json.String(value)
			case "--min-interval":
				n, ok := strconv.parse_i64(value)
				if !ok do return {}, false
				body["min_interval_s"] = json.Integer(n)
			case "--target":
				if value != "bot" do return {}, false
				target_given = true
				target["kind"] = json.String("bot")
			case "--agent-id", "--instance", "--bot":
				if value == "" do return {}, false
				target_given = true
				target_count += 1
				switch flag {
				case "--agent-id":
					target["kind"] = json.String("agent")
					target["agent_id"] = json.String(value)
				case "--instance":
					target["kind"] = json.String("instance")
					target["instance_id"] = json.String(value)
				case "--bot":
					target["kind"] = json.String("bot")
					target["bot_id"] = json.String(value)
				}
			case "--project":
				target_given = true
				target["project_id"] = json.String(value)
			case "--instance-strategy":
				target_given = true
				target["instance_strategy"] = json.String(value)
			case "--rule":
				target_given = true
				parts := strings.split(value, ":", context.temp_allocator)
				if len(parts) < 2 || len(parts) > 3 || parts[0] == "" || parts[1] == "" do return {}, false
				model := "*"
				if len(parts) == 3 {
					model = parts[2]
					if model == "" do return {}, false
				}
				rule := ctl_action_object()
				rule["bridge_id"] = json.String(parts[0])
				rule["provider"] = json.String(parts[1])
				rule["model"] = json.String(model)
				append(&rules, rule)
			case "--trigger", "--trigger-json":
				triggers_given = true
				trigger: json.Value
				ok := false
				if flag == "--trigger" {
					trigger, ok = ctl_action_trigger(value)
				} else {
					trigger, ok = ctl_parse_json_document(value)
					if _, object := trigger.(json.Object); !object do ok = false
				}
				if !ok do return {}, false
				append(&triggers, trigger)
			}
  case "--bridge-endpoint","--agent-token":
   if i+1>=len(args) do return {},false
   i+=1
  case:
   if strings.has_prefix(flag,"--") do return {},false
  }
 }
 if action == "create" {
		prompt, _ := body["prompt_text"].(json.String)
		if strings.trim_space(string(prompt)) == "" || !target_given do return {}, false
	}
	if has_flag(args, "--target") {
		if has_flag(args, "--agent-id") || has_flag(args, "--instance") do return {}, false
		if !has_flag(args, "--bot") do target_count += 1
	}
	if target_given {
		if target_count != 1 do return {}, false
		kind, _ := target["kind"].(json.String)
		if kind != "agent" && (len(rules) > 0 || has_flag(args, "--project") || has_flag(args, "--instance-strategy")) do return {}, false
		if kind == "agent" do target["rules"] = json.Array(rules)
		body["target"] = target
	}
	if triggers_given do body["triggers"] = json.Array(triggers)
	if action == "create" {
		return {method = .POST, path = ctl_api("actions"), body = httpc.json_body(body)}, true
	}
	return {method = .PATCH, path = ctl_api("actions", id), body = httpc.json_body(body)}, true
}


// Shorthand stays flat AND. Trees (including any/not) use --filter-file.
ctl_automation_check :: proc(pair:string)->(json.Value,bool) {
 at:=strings.index(pair,"=")
 if at<=0 || at==len(pair)-1 do return nil,false
 field,value:=pair[:at],pair[at+1:]
 op:="eq"
 if colon:=strings.index(value,":");colon>=0 {
  op=value[:colon];value=value[colon+1:]
 }
 check:=ctl_action_object()
 if !strings.contains(field,".") do field=strings.concatenate({"data.",field},context.temp_allocator)
 check["field"]=json.String(field)
 check["op"]=json.String(op)
 switch op {
 case "eq","ne": check["value"]=json.String(value)
 case "in","not_in":
  parts:=strings.split(value,"|",context.temp_allocator)
  values:=make(json.Array,len(parts),context.temp_allocator)
  for part,i in parts {if part=="" do return nil,false;values[i]=json.String(part)}
  check["value"]=values
 case "exists":
  if value!="true" && value!="false" do return nil,false
  check["value"]=json.Boolean(value=="true")
 case: return nil,false
 }
 return check,true
}

// All methods go through the bridge's authenticated envelope relay.
ctl_automation_call :: proc(tokens,args:[]string)->(string,string,bool) {
 verb:=pos(tokens,0)
 if verb=="" do verb="list"
 if !ctl_automation_flags_valid(verb,args) do return "","",false
 params:=ctl_action_object()
 switch verb {
 case "trigger-types":
 case "filter-test":
  for pair in ([]struct{flag,key:string}{{"--event-type","event_type"},{"--filter-file","filter"},{"--event-file","event"}}) {
   flag,key:=pair.flag,pair.key
   value:=option_value(args,flag,"")
   if value=="" do return "","",false
   if key=="event_type" {params[key]=json.String(value);continue}
   data,err:=os.read_entire_file(value,context.temp_allocator)
   if err!=nil do return "","",false
   parsed:json.Value
   if json.unmarshal(data,&parsed,allocator=context.temp_allocator)!=nil do return "","",false
   params[key]=parsed
  }
 case "list","show","create","update","delete","runs":
  req,ok:=ctl_automation_request(tokens,args)
  if !ok do return "","",false
  if verb!="list" && verb!="create" do params["id"]=json.String(pos(tokens,1))
  if verb=="create" || verb=="update" {
   text,encoded:=ctl_request_body_text(req.body)
   if !encoded do return "","",false
   value,parsed:=ctl_parse_json_document(text)
   if !parsed do return "","",false
   params["input"]=value
  }
  if verb=="runs" {
   for item in req.query {
    if item.name=="limit" {n,_:=strconv.parse_i64(item.value);params[item.name]=json.Integer(n)} else {params[item.name]=json.String(item.value)}
   }
  }
 case: return "","",false
 }
 bytes,err:=json.marshal(params,allocator=context.temp_allocator)
 if err!=nil do return "","",false
 return strings.concatenate({"agent.automations.",verb},context.temp_allocator),string(bytes),true
}
ctl_v2_automations :: proc(endpoint,token:string,tokens,args:[]string) {
 method,params,ok:=ctl_automation_call(tokens,args)
 if !ok {fmt.println(ctl_automation_help(pos(tokens,0)));return}
 ctl_agent_call(endpoint,token,method,params)
}

CTL_AUTOMATION_MUTATION_HELP :: `Targets (one; any target flag replaces the whole target, including rules):
  --bot <id>                      Owner's bot.
  --target bot [--bot <id>]        Omitting --bot selects the owner's bot.
  --instance <id>                 Owner's existing instance.
  --agent-id <id>                 Owner's durable agent.
  --project <id>                  Project for an agent target.
  --instance-strategy <strategy>  reuse (default) or fresh_per_run, agent only.
  --rule <bridge>:<provider>[:<model>]  Repeat in placement order; * is a wildcard.
Fields:
  --prompt <text>                 Prompt to deliver (required on create).
  --name <text>                   Optional display name.
  --min-interval <seconds>        Minimum time between runs (hub validates limits).
  --disabled / --disable          Save disabled.
  --enable                       Save enabled.
Triggers:
  --trigger <spec>                Repeat; replaces the whole trigger list on update.
                                 cron:<5-field expression>@<IANA timezone>
                                 event:<type>[,<field>=<op>:<value>]...
                                 every:<seconds> or at:<RFC3339>
  --trigger-json <json>           Full trigger object; repeat to replace triggers.
  --filter <field>=<op>:<value>    Filter on the preceding event trigger.
  --filter-file <path>            JSON filter tree on preceding event; any/all/not allowed.
  --entity <id>                   Pin preceding event trigger to an owned entity.
  --delay <seconds|Ns|Nm|Nh>       Preceding trigger delay; 0 disables, max 24 hours.
Filter shorthand: eq/ne use a string; in/not_in use | separated strings;
exists:true or exists:false. A missing op means eq. Bare fields mean data.<field>.
Several comma checks form all-of. Use --filter-file instead of shorthand for a tree.
Global transport flags: --bridge-endpoint <path>, --agent-token <token>.
Examples:
  ham-ctl automations create --prompt 'Review' --bot bot_1 --trigger 'cron:0 9 * * 1-5@Asia/Kolkata'
  ham-ctl automations create --prompt 'Summarize' --instance inst_1 --trigger 'event:chain.state,state=in:completed|cancelled' --entity chain_1 --delay 30
  ham-ctl automations update act_1 --trigger event:chain.state --filter-file rule.json
`
ctl_automation_help :: proc(verb:string)->string {
 switch verb {
 case "create","update":
  return strings.concatenate({"ham-ctl automations ",verb," ",("<id> " if verb=="update" else ""), "[flags]\n",CTL_AUTOMATION_MUTATION_HELP},context.temp_allocator)
 case "list": return "ham-ctl automations list\nList automations belonging to your instance owner. Example: ham-ctl automations list"
 case "show","delete":
  return strings.concatenate({"ham-ctl automations ",verb," <id>\nOwner-scoped automation ",verb,". Example: ham-ctl automations ",verb," act_1"},context.temp_allocator)
 case "runs": return `ham-ctl automations runs <id> [--limit <1..200>] [--before <created_at>] [--before-id <run_id>]
Returns run history and event_params._match {rev,nodes}; nodes are pre-order T/F.
Overlay only when the trigger revision matches; otherwise the rule was edited.
Example: ham-ctl automations runs act_1 --limit 20`
 case "trigger-types": return "ham-ctl automations trigger-types\nReturn event types, fields, allowed operators, values and effective limits. Example: ham-ctl automations trigger-types"
 case "filter-test": return `ham-ctl automations filter-test --event-type <type> --filter-file <path> --event-file <path>
Validate a JSON filter tree and evaluate a JSON sample event without emitting or storing it.
Returns valid/matched, per-node T/F trace, and validation path/reason.
Example: ham-ctl automations filter-test --event-type chain.state --filter-file rule.json --event-file sample.json`
 }
 return `ham-ctl automations <create|list|show|update|delete|runs|trigger-types|filter-test>
Owner-scoped event and cron automations, authenticated through the local bridge.
Use ham-ctl automations <verb> --help for flags and examples.
Action cards use ham-ctl actions/cards.
Example: ham-ctl automations list`
}


// Validate flags before any I/O, including file reads and destructive verbs.
ctl_automation_flags_valid :: proc(verb:string,args:[]string)->bool {
 for i:=0;i<len(args);i+=1 {
  flag:=args[i]
  if !strings.has_prefix(flag,"--") do continue
  takes_value:=true
  allowed:=false
  switch flag {
  case "--bridge-endpoint","--agent-token": allowed=true
  case "--enable","--disable","--disabled": allowed=verb=="create" || verb=="update";takes_value=false
  case "--name","--prompt","--min-interval","--agent-id","--project","--instance-strategy","--rule","--instance","--bot","--target","--trigger","--trigger-json","--filter","--entity","--delay":
   allowed=verb=="create" || verb=="update"
  case "--filter-file": allowed=verb=="create" || verb=="update" || verb=="filter-test"
  case "--event-type","--event-file": allowed=verb=="filter-test"
  case "--limit","--before","--before-id": allowed=verb=="runs"
  }
  if !allowed do return false
  if takes_value {
   if i+1>=len(args) || strings.has_prefix(args[i+1],"--") do return false
   i+=1
  }
 }
 return true
}
