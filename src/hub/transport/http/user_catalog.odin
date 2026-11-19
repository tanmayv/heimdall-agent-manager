package http

import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:time"
import events "odin_test:hub/service/events"
import domain "odin_test:hub/domain"
import eventinbox "odin_test:hub/service/eventinbox"
import nats "odin_test:lib/nats"

User_Catalog_Action :: enum {Attach, Next, Heartbeat}
User_Catalog_State :: struct {
	cursor: string,
	connection: ^nats.Connection,
	has_more, available: bool,
	last_page, last_heartbeat, last_connect: time.Tick,
}
user_catalog_destroy :: proc(s: ^User_Catalog_State) {
	delete(s.cursor)
	nats.destroy(s.connection)
	s^={}
}
// Unknown, oversized and malformed controls do no network work. Parsing uses
// owned JSON, not the websocket lifetime's temporary arena.
user_ws_catalog_receive :: proc(h: ^User_Handlers, handle: events.User_WS_Handle, owner: string, s: ^User_Catalog_State, frame: string) -> bool {
	if h.catalog==nil || len(frame)>1024 do return true
	arena:mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	scratch:=mem.dynamic_arena_allocator(&arena)
	value,err:=json.parse_string(frame,parse_integers=true,allocator=scratch)
	defer json.destroy_value(value,allocator=scratch)
	if err!=nil do return true
	obj,ok:=value.(json.Object)
	if !ok do return true
	typ,typed:=obj["type"].(json.String)
	if !typed do return true
	switch string(typ) {
	case "catalog_next":
		if len(obj)!=1 do return true
		return user_ws_catalog_step(h,handle,owner,s,.Next)
	case "client_heartbeat":
		for key in obj do if key!="type" && key!="at" do return true
		return user_ws_catalog_step(h,handle,owner,s,.Heartbeat)
	}
	return true
}
user_ws_catalog_step :: proc(h: ^User_Handlers, handle: events.User_WS_Handle, owner: string, s: ^User_Catalog_State, action: User_Catalog_Action) -> bool {
	if h.catalog==nil do return true
	switch action {
	case .Next:
		if !s.has_more || s.last_page._nsec!=0 && time.tick_since(s.last_page)<250*time.Millisecond do return true
	case .Heartbeat:
		// Never jump past an unfinished reconnect page. Live invalidations cover
		// new events once caught up, so heartbeats return only a watermark.
		if s.has_more || s.last_heartbeat._nsec!=0 && time.tick_since(s.last_heartbeat)<20*time.Second do return true
	case .Attach:
	}
	if s.connection==nil {
		if s.last_connect._nsec!=0 && time.tick_since(s.last_connect)<2*time.Second do return true
		s.last_connect=time.tick_now()
		s.connection,_=nats.connect(h.catalog.options)
	}
	if action==.Heartbeat {s.last_heartbeat=time.tick_now()} else {s.last_page=time.tick_now()}
	page:eventinbox.Catalog_Page
	defer eventinbox.catalog_page_destroy(&page)
	failed:=s.connection==nil
	if !failed {
		cursor:=s.cursor
		if action==.Heartbeat do cursor=""
		err:domain.Domain_Error
		page,err=eventinbox.catalog_read(s.connection,owner,"",cursor,200)
		failed=err.code!=.None
	}
	if failed {
		nats.destroy(s.connection);s.connection=nil
		if s.available do events.user_ws_send(h.event_bus,handle,`{"type":"resync_required","reason":"catalog_unavailable"}`)
		s.available=false
		return true
	}
	s.available=true
	typ:="catalog_replay"
	if action==.Heartbeat do typ="catalog_watermark"
	encoded,enc_err:=json.marshal(struct {
		type,catalog_cursor:string,
		events:[]json.Value,
		cursor_expired,has_more:bool,
	}{typ,page.catalog_cursor,page.events[:],page.cursor_expired,page.has_more})
	if enc_err!=nil do return false
	defer delete(encoded)
	events.user_ws_send(h.event_bus,handle,string(encoded))
	delete(s.cursor)
	s.cursor=page.catalog_cursor
	page.catalog_cursor=""
	s.has_more=page.has_more
	return true
}
