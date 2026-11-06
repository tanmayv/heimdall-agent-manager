// Reviewer #24 reproduction, extended with restart and both deletion-journal boundaries.
package owner_local
import "core:testing"
import "core:fmt"
import vault "odin_test:lib/vault"
@(test)
review_restore_tombstone_must_preserve_blob_live_in_backup :: proc(t:^testing.T) {
 context.allocator=context.temp_allocator
 f:=fixture(t);defer destroy(f);seed(t,f)
 g:=fixture(t);defer destroy(g);seed(t,g)
 original_kr:=g.kr;g.kr=f.kr;defer {g.kr=original_kr}
 blob:=linked_test_object(f,"blob","shared","binary")
 old:=linked_test_object(f,"artifact","old","old",linked_test_ref("blob","shared"))
 newer:=linked_test_object(f,"artifact","new","new",linked_test_ref("blob","shared"))
 for raw,i in ([2]string{blob,old}) {
  testing.expect_value(t,linked_test_call(f,"linked.put",fmt.tprintf("f_%d",i),raw).code,"ok")
  testing.expect_value(t,linked_test_call(g,"linked.put",fmt.tprintf("g_%d",i),raw).code,"ok")
 }
 testing.expect_value(t,linked_test_call(f,"linked.put","new",newer).code,"ok")
 testing.expect_value(t,linked_test_delete(f,"artifact","old","delete_old").code,"ok")
 testing.expect_value(t,linked_test_fetch(f,"blob","shared").code,"ok")
 pages:=make([dynamic]string,context.temp_allocator)
 cursor:=""
 for i in 0..<10 {
  result:=linked_test_page(f,cursor,"1")
  if !testing.expect_value(t,result.code,"ok") do return
  page:=linked_test_json(result.body)
  plain,opened:=vault.open(field(page,"manifest_cipher"),&f.kr,context.temp_allocator)
  testing.expect(t,opened==.Ok)
  append(&pages,plain)
  testing.expect_value(t,linked_test_call(g,"linked.restore",fmt.tprintf("restore_%d",i),plain).code,"ok")
  cursor=field(page,"next_cursor");if cursor=="" do break
 }
 testing.expect_value(t,linked_test_fetch(g,"artifact","new").code,"ok")

 testing.expect_value(t,linked_test_fetch(g,"blob","shared").code,"ok")
 testing.expect_value(t,field(linked_test_json(linked_test_fetch(g,"artifact","new").body),"record"),newer)
 testing.expect_value(t,field(linked_test_json(linked_test_fetch(g,"blob","shared").body),"record"),blob)
 testing.expect_value(t,linked_test_fetch(g,"artifact","old").code,"retired")
 close(&g.store);testing.expect(t,open(&g.store,g.path,"account","bridge","bridge_key"))
 testing.expect_value(t,linked_test_fetch(g,"blob","shared").code,"ok")
 testing.expect_value(t,linked_test_fetch(g,"artifact","new").code,"ok")
 // A genuine prior destination deletion still dominates the complete source.
 testing.expect_value(t,linked_test_delete(g,"blob","shared","destination_delete").code,"ok")
 for raw,i in pages {
  testing.expect_value(t,linked_test_call(g,"linked.restore",fmt.tprintf("retry_%d",i),raw).code,"ok")
 }
 testing.expect_value(t,linked_test_fetch(g,"blob","shared").code,"retired")
 testing.expect_value(t,linked_test_fetch(g,"artifact","new").code,"ok")
 // Ordinary source deletion still performs GC. Its explicit blob tombstone
 // must remove the old destination blob when that newer journal is imported.
 testing.expect_value(t,linked_test_delete(f,"artifact","new","source_delete_new").code,"ok")
 testing.expect_value(t,linked_test_fetch(f,"blob","shared").code,"retired")
 h:=fixture(t);defer destroy(h);seed(t,h)
 h_kr:=h.kr;h.kr=f.kr;defer {h.kr=h_kr}
 for raw,i in ([2]string{blob,old}) {
  testing.expect_value(t,linked_test_call(h,"linked.put",fmt.tprintf("h_%d",i),raw).code,"ok")
 }
 cursor=""
 for i in 0..<10 {
  result:=linked_test_page(f,cursor,"1")
  if !testing.expect_value(t,result.code,"ok") do return
  page:=linked_test_json(result.body)
  plain,opened:=vault.open(field(page,"manifest_cipher"),&f.kr,context.temp_allocator)
  testing.expect(t,opened==.Ok)
  testing.expect_value(t,linked_test_call(h,"linked.restore",fmt.tprintf("journal_%d",i),plain).code,"ok")
  cursor=field(page,"next_cursor");if cursor=="" do break
 }
 testing.expect_value(t,linked_test_fetch(h,"blob","shared").code,"retired")
 testing.expect_value(t,linked_test_fetch(h,"artifact","old").code,"retired")
 rows,_:=query(h.store.db,"PRAGMA foreign_key_check");testing.expect_value(t,len(rows),0)
}
