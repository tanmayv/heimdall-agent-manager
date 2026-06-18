package main

import "core:sync"
import "core:thread"

MESSAGE_QUEUE_CAP :: 8192

Message_Command :: struct {
	command: Command,
	result: Service_Result,
	done: bool,
	mutex: sync.Mutex,
	cond: sync.Cond,
}

Message_Command_Queue :: struct {
	items: [MESSAGE_QUEUE_CAP]^Message_Command,
	read_index: int,
	write_index: int,
	count: int,
	mutex: sync.Mutex,
	not_empty: sync.Cond,
	not_full: sync.Cond,
}

message_command_queue: Message_Command_Queue

message_queue_init :: proc() {
	message_command_queue = Message_Command_Queue{}
}

message_queue_start_worker :: proc() {
	thread.run(message_queue_worker)
}

message_queue_submit_command :: proc(command: Command) -> Service_Result {
	cmd := Message_Command{command = command}
	message_queue_enqueue(&cmd)
	message_command_wait(&cmd)
	return cmd.result
}

message_queue_enqueue :: proc(cmd: ^Message_Command) {
	q := &message_command_queue
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for q.count >= MESSAGE_QUEUE_CAP {
		sync.cond_wait(&q.not_full, &q.mutex)
	}
	q.items[q.write_index] = cmd
	q.write_index = (q.write_index + 1) % MESSAGE_QUEUE_CAP
	q.count += 1
	sync.cond_signal(&q.not_empty)
}

message_queue_dequeue :: proc() -> ^Message_Command {
	q := &message_command_queue
	sync.mutex_lock(&q.mutex)
	defer sync.mutex_unlock(&q.mutex)
	for q.count == 0 {
		sync.cond_wait(&q.not_empty, &q.mutex)
	}
	cmd := q.items[q.read_index]
	q.items[q.read_index] = nil
	q.read_index = (q.read_index + 1) % MESSAGE_QUEUE_CAP
	q.count -= 1
	sync.cond_signal(&q.not_full)
	return cmd
}

message_command_wait :: proc(cmd: ^Message_Command) {
	sync.mutex_lock(&cmd.mutex)
	defer sync.mutex_unlock(&cmd.mutex)
	for !cmd.done {
		sync.cond_wait(&cmd.cond, &cmd.mutex)
	}
}

message_command_complete :: proc(cmd: ^Message_Command) {
	sync.mutex_lock(&cmd.mutex)
	cmd.done = true
	sync.cond_signal(&cmd.cond)
	sync.mutex_unlock(&cmd.mutex)
}

message_queue_worker :: proc() {
	for {
		cmd := message_queue_dequeue()
		cmd.result = message_service_process_serialized_command(cmd.command)
		message_command_complete(cmd)
	}
}
