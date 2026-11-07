package contracts

// Local physical transport identity only. This is not owner task authority.
PTY_Notification_Runtime :: struct { agent_instance_id, launch_epoch, run_count: string }
PTY_Notification_Delivery :: struct {
    protocol_version: int,
    source: PTY_Notification_Runtime,
    pid, launch_key, operation_id, delivery_id, message: string,
    interrupt: bool,
}
PTY_Notification_Receipt :: struct {
    protocol_version: int,
    source: PTY_Notification_Runtime,
    pid, launch_key, delivery_id, message_bytes_written, status: string,
    esc_written, enter_written: bool,
}
PTY_Notification_Action :: enum { Invalid, Stale, Recover, Resume, Complete }
pty_notification_id_valid :: proc(s: string) -> bool {
    if len(s)==0 || len(s)>256 do return false
    for b in s do if b<0x21 || b>0x7e do return false
    return true
}
pty_notification_runtime_valid :: proc(r: PTY_Notification_Runtime) -> bool {
    return pty_notification_id_valid(r.agent_instance_id) && pty_notification_id_valid(r.launch_epoch) && owner_field_valid(r.run_count,"positive")
}
pty_notification_message_valid :: proc(s: string) -> bool {
    if len(s)==0 || len(s)>16384 || !pty_notification_utf8_valid(s) do return false
    for c in s do if c<0x20 && c!=0x0a && c!=0x09 || c>=0x7f && c<=0x9f do return false
    return true
}
pty_notification_utf8_valid :: proc(s: string) -> bool {
    for i := 0; i < len(s); {
        a := s[i]
        if a < 0x80 { i += 1; continue }
        n := 0
        lo, hi: u8 = 0x80, 0xbf
        if a >= 0xc2 && a <= 0xdf { n = 2 }
        else if a >= 0xe0 && a <= 0xef {
            n = 3
            if a == 0xe0 do lo = 0xa0
            if a == 0xed do hi = 0x9f
        } else if a >= 0xf0 && a <= 0xf4 {
            n = 4
            if a == 0xf0 do lo = 0x90
            if a == 0xf4 do hi = 0x8f
        } else { return false }
        if i+n > len(s) || s[i+1] < lo || s[i+1] > hi do return false
        for j in 2..<n do if s[i+j] < 0x80 || s[i+j] > 0xbf do return false
        i += n
    }
    return true
}
pty_notification_receipt_action :: proc(intent: PTY_Notification_Delivery, receipt: PTY_Notification_Receipt, host_state_survives: bool) -> PTY_Notification_Action {
    if intent.source != receipt.source || intent.pid != receipt.pid || intent.launch_key != receipt.launch_key || intent.delivery_id != receipt.delivery_id do return .Stale
    if !host_state_survives || receipt.status == "recovery_required" do return .Recover
    if receipt.status == "child_mismatch" do return .Stale
    if !pty_notification_runtime_valid(intent.source) || !pty_notification_id_valid(intent.launch_key) || !pty_notification_id_valid(intent.delivery_id) || !pty_notification_id_valid(intent.operation_id) || !owner_field_valid(intent.pid,"positive") || !owner_field_valid(receipt.message_bytes_written,"counter") || !pty_notification_message_valid(intent.message) || intent.protocol_version != 1 || receipt.protocol_version != 1 do return .Invalid
    written: i64
    for b in receipt.message_bytes_written do written = written*10+i64(b-'0')
    if written > i64(len(intent.message)) || !intent.interrupt && receipt.esc_written do return .Invalid
    if intent.interrupt && !receipt.esc_written && (written > 0 || receipt.enter_written) do return .Invalid
    if receipt.enter_written && written != i64(len(intent.message)) do return .Invalid
    complete := receipt.enter_written && written == i64(len(intent.message)) && (!intent.interrupt || receipt.esc_written)
    if receipt.status == "delivered" { if complete do return .Complete; return .Invalid }
    if receipt.status == "partial" && !complete do return .Resume
    return .Invalid
}
