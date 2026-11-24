package eventinbox

import "core:fmt"
import "base:runtime"
import "core:sync"
import "core:strings"
import "core:time"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

Cached_Chain :: struct {
 key: string,
 rows: [dynamic]domain.Event_Subscription,
 snapshots: [dynamic]domain.Event_Notice_Snapshot,
}
destroy_cached_chain :: proc(entry: Cached_Chain) {
 for row in entry.rows {value := row; domain.event_subscription_destroy(&value)}
 for snapshot in entry.snapshots {value := snapshot; domain.event_notice_snapshot_destroy(&value)}
 delete(entry.rows); delete(entry.snapshots); delete(entry.key)
}
clear_subscription_cache :: proc(r: ^Runtime) {
 context.allocator = r.cache_allocator
 for _, entry in r.subscription_cache do destroy_cached_chain(entry)
 delete(r.subscription_cache); r.subscription_cache = nil
 r.subscriptions_ready = false
 r.subscription_revision = 0; r.subscription_reconcile = {}
}
cache_chain_rows :: proc(r: ^Runtime, rows: []domain.Event_Subscription, snapshots: []domain.Event_Notice_Snapshot) {
 // Transfer all row/string ownership; the outer arrays remain caller owned.
 scopes := make(map[string]string)
 defer delete(scopes)
 for row in rows {
  scope := fmt.tprintf("%s/%s",row.owner_user_id,row.chain_id)
  entry, found := r.subscription_cache[scope]
  if !found do entry.key = strings.clone(scope)
  append(&entry.rows, row)
  r.subscription_cache[entry.key] = entry
  scopes[row.subscription_id] = entry.key
 }
 for snapshot in snapshots {
  if scope, found := scopes[snapshot.subscription_id]; found {
   entry := r.subscription_cache[scope]
   append(&entry.snapshots, snapshot)
   r.subscription_cache[entry.key] = entry
  } else {
   value := snapshot; domain.event_notice_snapshot_destroy(&value)
  }
 }
}
refresh_subscription_cache :: proc(r: ^Runtime, repo: iface.Event_Subscription_Repository, now: time.Tick) -> bool {
 context.allocator = r.cache_allocator
 changes, err := repo.changes(repo.ctx, r.subscription_revision)
 if err.code != .None do return false
 defer {
  for change in changes {delete(change.owner_user_id); delete(change.chain_id)}
  delete(changes)
 }
 full := !r.subscriptions_ready || now._nsec-r.subscription_reconcile._nsec >= i64(reconcile_interval(r.service))
 if full {
  rows, rerr := repo.all(repo.ctx)
  if rerr.code != .None do return false
  snapshots, serr := repo.notice_snapshot(repo.ctx)
  if serr.code != .None {subscription_rows_destroy(rows); return false}
  revision := r.subscription_revision
  clear_subscription_cache(r)
  r.subscription_revision = revision
  r.subscription_cache = make(map[string]Cached_Chain)
  cache_chain_rows(r, rows, snapshots)
  delete(rows); delete(snapshots)
  r.subscription_reconcile = now
 } else {
  for change in changes {
   rows, rerr := repo.chain_rows(repo.ctx, change.owner_user_id, change.chain_id)
   if rerr.code != .None do return false
   snapshots, serr := repo.chain_snapshot(repo.ctx, change.owner_user_id, change.chain_id)
   if serr.code != .None {subscription_rows_destroy(rows); return false}
   key := fmt.tprintf("%s/%s",change.owner_user_id,change.chain_id)
   if entry, found := r.subscription_cache[key]; found {
    delete_key(&r.subscription_cache,key); destroy_cached_chain(entry)
   }
   cache_chain_rows(r, rows, snapshots)
   delete(rows); delete(snapshots)
   // Target and receipt changes must rescan promptly, not wait for the slow reconcile.
   published(r.service, fmt.tprintf("ev.%s.chain.%s.state",change.owner_user_id,change.chain_id))
  }
 }
 for change in changes do r.subscription_revision = max(r.subscription_revision,change.revision)
 r.subscriptions_ready = true
 if full || len(changes)>0 {
  s := r.service
  context.allocator = runtime.heap_allocator()
  sync.mutex_lock(&s.notice_dirty.mutex)
  for key in s.watched_scopes do delete(key)
  delete(s.watched_scopes)
  s.watched_scopes=make(map[string]bool)
  for key in r.subscription_cache do s.watched_scopes[strings.clone(key)]=true
  s.interest_ready=true
  sync.mutex_unlock(&s.notice_dirty.mutex)
 }
 return true
}
cached_subscription_rows :: proc(r: ^Runtime) -> []domain.Event_Subscription {
 rows := make([dynamic]domain.Event_Subscription)
 for _, entry in r.subscription_cache do append(&rows,..entry.rows[:])
 return rows[:]
}
cached_notice_snapshots :: proc(r: ^Runtime) -> []domain.Event_Notice_Snapshot {
 rows := make([dynamic]domain.Event_Notice_Snapshot)
 for _, entry in r.subscription_cache do append(&rows,..entry.snapshots[:])
 return rows[:]
}
