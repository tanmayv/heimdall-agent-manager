package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:net"
import "core:thread"
import c "core:c"

foreign import sqlite3_lib "system:sqlite3"

@(default_calling_convention="c")
foreign sqlite3_lib {
	sqlite3_backup_init   :: proc(pDest: sqlite3, zDestName: cstring, pSource: sqlite3, zSourceName: cstring) -> rawptr ---
	sqlite3_backup_step   :: proc(pBackup: rawptr, nPage: c.int) -> c.int ---
	sqlite3_backup_finish :: proc(pBackup: rawptr) -> c.int ---
}

SQLITE_OK   :: 0
SQLITE_DONE :: 101

backup_scheduler_started: bool

backup_scheduler_start :: proc() {
	if backup_scheduler_started do return
	backup_scheduler_started = true
	thread.run(backup_scheduler_worker)
}

backup_scheduler_worker :: proc() {
	// Sleep for 30 seconds on startup to let the daemon fully initialize all databases
	time.sleep(30 * time.Second)
	
	for {
		backup_scheduler_tick()
		// Sleep for 1 hour
		time.sleep(60 * 60 * time.Second)
	}
}

backup_scheduler_tick :: proc() {
	// Resolve backup_dir preference using system/empty user
	backup_dir_pref := memory_auditor_resolve_pref("", "backup_dir")
	defer delete(backup_dir_pref)
	
	if backup_dir_pref == "" do return
	
	backup_root := expand_home(backup_dir_pref)
	defer delete(backup_root)
	
	// Check if backup has already been taken today
	if backup_already_taken_today(backup_root) do return
	
	fmt.println("BACKUP SCHEDULER: No backup found for today. Triggering automatic daily backup...")
	success, msg := backup_execute("")
	if success {
		fmt.printfln("BACKUP SCHEDULER: Automatic backup completed successfully: %s", msg)
	} else {
		fmt.printfln("BACKUP SCHEDULER: Automatic backup failed: %s", msg)
	}
}

backup_already_taken_today :: proc(backup_root: string) -> bool {
	infos, err := os.read_directory_by_path(backup_root, -1, context.temp_allocator)
	if err != 0 do return false
	
	now := time.now()
	year, month, day := time.date(now)
	today_prefix := fmt.tprintf("backup_%d%02d%02d_", year, int(month), day)
	
	for info in infos {
		full_path := fmt.tprintf("%s/%s", backup_root, info.name)
		defer delete(full_path)
		if os.is_dir(full_path) && strings.has_prefix(info.name, today_prefix) {
			return true
		}
	}
	return false
}

backup_execute :: proc(author: string) -> (ok: bool, message: string) {
	backup_dir_pref := memory_auditor_resolve_pref(author, "backup_dir")
	defer delete(backup_dir_pref)
	
	if backup_dir_pref == "" {
		return false, "Backup directory preference 'backup_dir' is not configured."
	}
	
	// Expand home
	backup_root := expand_home(backup_dir_pref)
	defer delete(backup_root)
	
	// Generate dated folder name: backup_YYYYMMDD_HHMMSS
	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec := time.clock(now)
	
	folder_name := fmt.tprintf("backup_%d%02d%02d_%02d%02d%02d", year, int(month), day, hour, min, sec)
	dest_dir := fmt.tprintf("%s/%s", backup_root, folder_name)
	defer delete(dest_dir)
	
	// Ensure dest dir exists
	if os.make_directory_all(dest_dir) != nil {
		return false, fmt.tprintf("Failed to create backup destination directory: %s", dest_dir)
	}
	
	fmt.printfln("BACKUP: Triggering full database backup to '%s'...", dest_dir)
	
	// List of databases to backup
	DBS := []struct {
		name: string,
		db:   sqlite3,
	}{
		{"task.db", task_db.db},
		{"tokens.db", auth_db.db},
		{"templates.db", agent_template_db.db},
		{"messages.db", message_db.db},
		{"preference.db", user_pref_db.db},
		{"audits.db", audit_db.db},
		{"memory.db", memory_db.db},
	}
	
	success_count := 0
	failed_names := make([dynamic]string, context.allocator)
	defer delete(failed_names)
	
	for db_info in DBS {
		if db_info.db == nil do continue
		
		dest_file_path := fmt.tprintf("%s/%s", dest_dir, db_info.name)
		defer delete(dest_file_path)
		
		if backup_single_db(db_info.db, dest_file_path) {
			success_count += 1
		} else {
			append(&failed_names, strings.clone(db_info.name))
		}
	}
	
	if success_count == 0 && len(DBS) > 0 {
		return false, "Failed to backup all databases."
	}
	
	if len(failed_names) > 0 {
		msg := fmt.tprintf("Backup completed partially. Successfully backed up %d databases. Failed databases: %v. Destination: %s", 
			success_count, failed_names, dest_dir)
		return true, msg
	}
	
	return true, fmt.tprintf("Backup completed successfully! Backed up %d databases to '%s'.", success_count, dest_dir)
}

backup_single_db :: proc(src_db: sqlite3, dest_path: string) -> bool {
	if src_db == nil do return false

	dest_db: sqlite3 = nil
	rc := sqlite3_open(cstring(raw_data(dest_path)), &dest_db)
	if rc != SQLITE_OK {
		fmt.printfln("backup_single_db: failed to open dest db '%s': %d", dest_path, rc)
		return false
	}
	defer sqlite3_close(dest_db)

	backup := sqlite3_backup_init(dest_db, "main", src_db, "main")
	if backup == nil {
		fmt.printfln("backup_single_db: failed to init backup from src to dest '%s': %s", dest_path, sqlite3_errmsg(dest_db))
		return false
	}

	rc = sqlite3_backup_step(backup, -1) // -1 copies the entire database
	_ = sqlite3_backup_finish(backup)

	if rc != SQLITE_DONE {
		fmt.printfln("backup_single_db: backup step failed for '%s': %d", dest_path, rc)
		return false
	}

	return true
}

handle_backup_trigger :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	
	success, message := backup_execute(author)
	
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":`)
	strings.write_string(&b, success ? "true" : "false")
	strings.write_string(&b, `,"message":"`)
	json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	
	write_response(client, success ? 200 : 500, success ? "OK" : "Internal Server Error", strings.to_string(b))
}

// ==========================================
// NEW: Backup Listing and Recovery Support
// ==========================================

Backup_Record :: struct {
	name:               string,
	created_at_unix_ms: i64,
	path:               string,
	db_count:           int,
}

backup_list :: proc(author: string) -> (backups: []Backup_Record, ok: bool, message: string) {
	backup_dir_pref := memory_auditor_resolve_pref(author, "backup_dir")
	defer delete(backup_dir_pref)
	
	if backup_dir_pref == "" {
		return nil, false, "Backup directory preference 'backup_dir' is not configured."
	}
	
	backup_root := expand_home(backup_dir_pref)
	defer delete(backup_root)
	
	if !os.is_dir(backup_root) {
		return nil, true, ""
	}
	
	infos, err := os.read_directory_by_path(backup_root, -1, context.allocator)
	if err != 0 {
		return nil, false, fmt.tprintf("Failed to read backup directory: %s", backup_root)
	}
	defer {
		for info in infos do os.file_info_delete(info, context.allocator)
		delete(infos)
	}
	
	list := make([dynamic]Backup_Record, context.allocator)
	
	for info in infos {
		if !os.is_dir(info.fullpath) do continue
		if !strings.has_prefix(info.name, "backup_") do continue
		
		db_count := 0
		db_infos, db_err := os.read_directory_by_path(info.fullpath, -1, context.temp_allocator)
		if db_err == 0 {
			for db_info in db_infos {
				if !os.is_dir(db_info.fullpath) && strings.has_suffix(db_info.name, ".db") {
					db_count += 1
				}
			}
		}
		
		created_ms := time.to_unix_nanoseconds(info.modification_time) / 1_000_000
		
		append(&list, Backup_Record{
			name = strings.clone(info.name),
			created_at_unix_ms = created_ms,
			path = strings.clone(info.fullpath),
			db_count = db_count,
		})
	}
	
	// Sort backups by name descending (newest first)
	for i := 0; i < len(list); i += 1 {
		for j := i + 1; j < len(list); j += 1 {
			if strings.compare(list[i].name, list[j].name) < 0 {
				temp := list[i]
				list[i] = list[j]
				list[j] = temp
			}
		}
	}
	
	return list[:], true, ""
}

handle_backup_list :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	
	list, success, message := backup_list(author)
	defer {
		if success {
			for b in list {
				delete(b.name)
				delete(b.path)
			}
			delete(list)
		}
	}
	
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":`)
	strings.write_string(&b, success ? "true" : "false")
	if success {
		strings.write_string(&b, `,"backups":[`)
		for item, idx in list {
			if idx > 0 do strings.write_string(&b, `,`)
			strings.write_string(&b, `{"name":"`)
			json_write_string(&b, item.name)
			strings.write_string(&b, `","path":"`)
			json_write_string(&b, item.path)
			strings.write_string(&b, `","created_at_unix_ms":`)
			strings.write_string(&b, fmt.tprintf("%d", item.created_at_unix_ms))
			strings.write_string(&b, `,"db_count":`)
			strings.write_string(&b, fmt.tprintf("%d", item.db_count))
			strings.write_string(&b, `}`)
		}
		strings.write_string(&b, `]`)
	} else {
		strings.write_string(&b, `,"message":"`)
		json_write_string(&b, message)
		strings.write_string(&b, `"`)
	}
	strings.write_string(&b, `}`)
	
	write_response(client, success ? 200 : 500, success ? "OK" : "Internal Server Error", strings.to_string(b))
}

backup_restore :: proc(author, folder_name: string) -> (ok: bool, message: string) {
	if folder_name == "" {
		return false, "Restore requires a target backup folder name."
	}
	
	backup_dir_pref := memory_auditor_resolve_pref(author, "backup_dir")
	defer delete(backup_dir_pref)
	
	if backup_dir_pref == "" {
		return false, "Backup directory preference 'backup_dir' is not configured."
	}
	
	backup_root := expand_home(backup_dir_pref)
	defer delete(backup_root)
	
	source_dir := fmt.tprintf("%s/%s", backup_root, folder_name)
	defer delete(source_dir)
	
	if !os.is_dir(source_dir) {
		return false, fmt.tprintf("Backup folder '%s' does not exist.", folder_name)
	}
	
	fmt.printfln("BACKUP: Restoring all databases from backup '%s'...", source_dir)
	
	DBS := []struct {
		name: string,
		db:   sqlite3,
	}{
		{"task.db", task_db.db},
		{"tokens.db", auth_db.db},
		{"templates.db", agent_template_db.db},
		{"messages.db", message_db.db},
		{"preference.db", user_pref_db.db},
		{"audits.db", audit_db.db},
		{"memory.db", memory_db.db},
	}
	
	success_count := 0
	failed_names := make([dynamic]string, context.allocator)
	defer delete(failed_names)
	
	for db_info in DBS {
		if db_info.db == nil do continue
		
		source_file_path := fmt.tprintf("%s/%s", source_dir, db_info.name)
		defer delete(source_file_path)
		
		if !os.is_file(source_file_path) do continue
		
		if restore_single_db(db_info.db, source_file_path) {
			success_count += 1
		} else {
			append(&failed_names, strings.clone(db_info.name))
		}
	}
	
	if success_count == 0 {
		return false, "Failed to restore any databases from the backup."
	}
	
	// Graceful Daemon Restart: exit process to let systemd cleanly restart the daemon
	thread.run(backup_restore_restart_worker)
	
	if len(failed_names) > 0 {
		msg := fmt.tprintf("Restore completed partially. Successfully restored %d databases. Failed: %v. Daemon is restarting...", 
			success_count, failed_names)
		return true, msg
	}
	
	return true, fmt.tprintf("Restore completed successfully! Restored %d databases. Daemon is restarting to apply changes...", success_count)
}

backup_restore_restart_worker :: proc() {
	time.sleep(1 * time.Second)
	fmt.println("SYSTEM: Database restore complete. Exiting process to trigger systemd cold restart...")
	os.exit(0)
}

restore_single_db :: proc(dest_db: sqlite3, source_path: string) -> bool {
	if dest_db == nil do return false

	source_db: sqlite3 = nil
	rc := sqlite3_open(cstring(raw_data(source_path)), &source_db)
	if rc != SQLITE_OK {
		fmt.printfln("restore_single_db: failed to open source db '%s': %d", source_path, rc)
		return false
	}
	defer sqlite3_close(source_db)

	backup := sqlite3_backup_init(dest_db, "main", source_db, "main")
	if backup == nil {
		fmt.printfln("restore_single_db: failed to init restore backup to dest: %s", sqlite3_errmsg(dest_db))
		return false
	}

	rc = sqlite3_backup_step(backup, -1) // -1 copies the entire database
	_ = sqlite3_backup_finish(backup)

	if rc != SQLITE_DONE {
		fmt.printfln("restore_single_db: restore step failed for '%s': %d", source_path, rc)
		return false
	}

	return true
}

handle_backup_restore :: proc(client: net.TCP_Socket, body: string) {
	author, ok := task_author_from_body(client, body)
	if !ok do return
	
	folder_name := extract_json_string(body, "backup_name", extract_json_string(body, "name", ""))
	success, message := backup_restore(author, folder_name)
	
	b := strings.builder_make()
	strings.write_string(&b, `{"ok":`)
	strings.write_string(&b, success ? "true" : "false")
	strings.write_string(&b, `,"message":"`)
	json_write_string(&b, message)
	strings.write_string(&b, `"}`)
	
	write_response(client, success ? 200 : 500, success ? "OK" : "Internal Server Error", strings.to_string(b))
}
