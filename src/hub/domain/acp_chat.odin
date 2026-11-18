package domain

ACP_Assistant_Turn :: struct {
    agent_instance_id, launch_epoch, turn_id, message_id: string,
    revision: i64,
    payload_hash: string,
}
