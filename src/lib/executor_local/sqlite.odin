package executor_local

import "core:c"
import "core:strings"

when ODIN_OS == .Windows {
    foreign import sqlite "system:sqlite3.lib"
} else {
    foreign import sqlite "system:sqlite3"
}
DB :: distinct rawptr
Stmt :: distinct rawptr
@(default_calling_convention="c")
foreign sqlite {
    sqlite3_progress_handler :: proc(db:DB,n:c.int,callback:proc "c"(rawptr)->c.int,data:rawptr) ---
    sqlite3_open :: proc(path: cstring, db: ^DB) -> c.int ---
    sqlite3_close :: proc(db: DB) -> c.int ---
    sqlite3_get_autocommit :: proc(db:DB)->c.int ---
    sqlite3_errcode :: proc(db:DB)->c.int ---
    sqlite3_exec :: proc(db: DB, sql: cstring, cb, arg, err: rawptr) -> c.int ---
    sqlite3_prepare_v2 :: proc(db: DB, sql: cstring, n: c.int, stmt: ^Stmt, tail: rawptr) -> c.int ---
    sqlite3_finalize :: proc(stmt: Stmt) -> c.int ---
    sqlite3_step :: proc(stmt: Stmt) -> c.int ---
    sqlite3_bind_text :: proc(stmt: Stmt, index: c.int, value: cstring, n: c.int, destructor: rawptr) -> c.int ---
    sqlite3_column_text :: proc(stmt: Stmt, index: c.int) -> cstring ---
    sqlite3_column_bytes :: proc(stmt:Stmt,index:c.int)->c.int ---
    sqlite3_column_count :: proc(stmt: Stmt) -> c.int ---
}
exec :: proc(db: DB, sql: string) -> bool {
    return sqlite3_exec(db, strings.clone_to_cstring(sql, context.temp_allocator), nil, nil, nil) == 0
}
// Every caller holds Store.mutex; no network I/O is permitted here.
// Result strings are request-temporary. All values use bound parameters.
query :: proc(db: DB, sql: string, args: ..string) -> (rows: [dynamic][]string, ok: bool) {
    stmt: Stmt
    if sqlite3_prepare_v2(db, strings.clone_to_cstring(sql, context.temp_allocator), -1, &stmt, nil) != 0 do return nil, false
    defer sqlite3_finalize(stmt)
    for arg, i in args {
        if sqlite3_bind_text(stmt, c.int(i+1), strings.clone_to_cstring(arg, context.temp_allocator), c.int(len(arg)), rawptr(~uintptr(0))) != 0 do return nil, false
    }
    rows = make([dynamic][]string, context.temp_allocator)
    for {
        rc := sqlite3_step(stmt)
        if rc == 101 do return rows, true
        if rc != 100 do return nil, false
        row := make([]string, int(sqlite3_column_count(stmt)), context.temp_allocator)
        for &col, i in row {
            n:=int(sqlite3_column_bytes(stmt,c.int(i)))
            bytes:=([^]byte)(rawptr(sqlite3_column_text(stmt,c.int(i))))[:n]
            col=strings.clone(string(bytes),context.temp_allocator)
        }
        append(&rows, row)
    }
}
