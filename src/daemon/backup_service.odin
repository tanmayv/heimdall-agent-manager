package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:net"
import "core:thread"

foreign import sqlite3_lib "system:sqlite3"

@(default_calling_convention="c")
foreign sqlite3_lib {
	sqlite3_open          :: proc(filename: cstring, ppDb: ^sqlite3) -> c.int ---
	sqlite3_close         :: proc(db: sqlite3) -> c.int ---
	sqlite3_backup_init   :: proc(pDest: sqlite3, zDestName: cstring, pSource: sqlite3, zSourceName: cstring) -> rawptr ---
	sqlite3_backup_step   :: proc(pBackup: rawptr, nPage: c.int) -> c.int ---
	sqlite3_backup_finish :: proc(pBackup: rawptr) -> c.int ---
	sqlite3_errmsg        :: proc(db: sqlite3) -> cstring ---
}

SQLITE_OK   :: 0
SQLITE_DONE :: 101

backup_scheduler_started: bool
backup_scheduler_thread: ^thread.Thread

backup_scheduler_start :: proc() {
	if backup_scheduler_started do return
	backup_scheduler_started = true
	backup_scheduler_thread = thread.create_and_run(backup_scheduler_worker)
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
		if info.is_dir && strings.has_prefix(info.name, today_prefix) {
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
	if !os.make_directory_all(dest_dir) {
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

	rc = sqlite3_backup_step(backup, -1) // -1 copies the entire database in one step
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
