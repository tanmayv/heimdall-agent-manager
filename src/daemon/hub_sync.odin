package main

import "core:fmt"
import "core:thread"
import "core:time"

hub_sync_cursor_seq: i64

hub_sync_init :: proc() {
	hub_sync_cursor_seq = 0
}

hub_sync_start_worker :: proc() {
	if hub_adapter_config.enabled {
		thread.run(hub_sync_worker)
	}
}

hub_sync_worker :: proc() {
	for {
		hub_sync_poll_once()
		time.sleep(500 * time.Millisecond)
	}
}

hub_sync_poll_once :: proc() -> int {
	if !hub_adapter_config.enabled do return 0
	task_store_retry_pending_archives()
	records := central_hub_poll(hub_adapter_config.user_id, hub_adapter_config.namespace, hub_sync_cursor_seq, 100)
	applied := 0
	for record in records {
		if record.source_daemon_id == hub_adapter_config.local_daemon_id {
			// Local records are already applied to the in-memory cache; ack and advance cursor.
			central_hub_ack(record.user_id, record.namespace, record.record_id)
			if record.record_seq > hub_sync_cursor_seq do hub_sync_cursor_seq = record.record_seq
			continue
		}
		if hub_adapter_apply_polled_record(record) {
			applied += 1
			if record.record_seq > hub_sync_cursor_seq do hub_sync_cursor_seq = record.record_seq
		} else {
			fmt.println("hub_sync apply_failed", record.record_id, "payload_type", record.payload_type)
		}
	}
	return applied
}
