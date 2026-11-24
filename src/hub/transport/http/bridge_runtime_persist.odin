package http

import "core:sync"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import bridge_service "odin_test:hub/service/bridge"
import bridge_runtime_service "odin_test:hub/service/bridge_runtime"
import project_service "odin_test:hub/service/project"

// Runtime admission and frame writers share this outer transaction boundary.
// Take it BEFORE snapshotting connection state, and release state_mutex BEFORE
// any DB operation. An old operation can commit before a newer hello admission;
// that admission overwrites its durable state. Once admission commits, every
// subsequent old operation sees retired and drops. Old operations must never
// commit after the newer admission commits. Socket I/O and effects follow commit.
bridge_persist_begin :: proc(h: ^Bridge_Handlers) -> (iface.Unit_Of_Work, bool, domain.Domain_Error) {
	// Repository doubles in isolated transport tests have no transaction backend.
	// Production always supplies the factory in app/wiring.odin.
	if h.uow_factory == nil do return {}, true, {}
	uow, ok, err := iface.unit_of_work_begin(h.uow_factory)
	if !ok do return {}, false, err
	if uow.nested {
		iface.unit_of_work_rollback(&uow)
		return {}, false, domain.domain_error(.Conflict, "runtime persistence requires an outer unit of work")
	}
	return uow, true, {}
}

bridge_persist_rollback :: proc(uow: ^iface.Unit_Of_Work) {
	old := uow^
	uow^ = {}
	iface.unit_of_work_rollback(&old)
}

bridge_persist_commit :: proc(uow: ^iface.Unit_Of_Work) -> (bool, domain.Domain_Error) {
	old := uow^
	uow^ = {}
	if old.commit == nil do return true, {}
	return iface.unit_of_work_commit(&old)
}

bridge_admit_hello :: proc(h: ^Bridge_Handlers, admitted: domain.Bridge, token, hostname, os_name, arch, text, version, commit_sha, build_timestamp, validation_url: string) -> (bridge_runtime_service.Hello_Result, domain.Bridge, bool, domain.Domain_Error) {
	uow, opened, err := bridge_persist_begin(h)
	if !opened do return {}, {}, false, err
	old: ^project_service.Bridge_Runtime_Connection
	connection: ^project_service.Bridge_Runtime_Connection
	committed := false
	defer {
		bridge_persist_rollback(&uow)
		// Retirement may shut sockets down, so it is outside the UoW even on failure.
		if old != nil {
			_ = project_service.bridge_runtime_connection_send_farewell(old, bridge_connection_replaced_payload())
			project_service.bridge_runtime_connection_retire(h.bridge_runtime_registry, old)
		}
		if connection != nil {
			if !committed do project_service.bridge_runtime_registry_mark_offline(h.bridge_runtime_registry, connection.bridge_id, connection.generation)
			project_service.bridge_runtime_connection_release(h.bridge_runtime_registry, connection)
		}
	}
	hello, accepted, hello_err := bridge_runtime_service.runtime_accept_hello(h.bridge_runtime_registry, admitted.bridge_id, json_int(text, "protocol_version", 1), validation_url, string(admitted.owner_user_id), deferred_retirement=&old)
	if !accepted do return {}, {}, false, hello_err
	connection = project_service.bridge_runtime_connection_acquire(h.bridge_runtime_registry, admitted.bridge_id, hello.generation)
	if connection == nil do return {}, {}, false, domain.domain_error(.Bridge_Offline, "bridge admission replaced")
	project_service.connection_state_lock(connection)
	retired := sync.atomic_load(&connection.retired)
	project_service.connection_state_unlock(connection)
	if retired do return {}, {}, false, domain.domain_error(.Bridge_Offline, "bridge admission retired")
	bridge, saved, save_err := bridge_service.bridge_runtime_connect(h.bridges, token, hostname, os_name, arch, text, version, commit_sha, build_timestamp)
	if !saved do return {}, {}, false, save_err
	project_service.connection_state_lock(connection)
	bridge_record_hello_metadata(connection, text)
	project_service.connection_state_unlock(connection)
	committed, err = bridge_persist_commit(&uow)
	if !committed {
		domain.bridge_destroy(&bridge)
		return {}, {}, false, err
	}
	return hello, bridge, true, {}
}
