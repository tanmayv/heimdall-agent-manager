package owner_local

import "core:os"
import "core:strings"
import "core:testing"

// C1 guard: the store has ONE clock source. Every proc of this package that
// takes the store and a time (s:^Store, now:i64) derives its time from
// store_now(s,now) (the injectable Store.clock hook, never earlier than the
// store's high-water clock) before any decision or signed time, and no
// non-test source reads the wall clock itself. The allowlist names the only
// exceptions.
// reconcile_clock is the trusted local recovery API: it is handed a trusted
// time explicitly (generation-checked), never a caller's decision time.
// lease_deadlines is a pure helper (C3): it uses the caller's derived time.
CLOCK_SOURCE_ALLOWLIST :: [?]string{"store_now","reconcile_clock","lease_deadlines"}

@(test)
clock_source_single_store_now_guard :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    entries,err:=os.read_directory_by_path(#directory,-1,context.temp_allocator)
    if !testing.expect(t,err==nil,"read package sources") do return
    checked:=0
    for e in entries {
        if !strings.has_suffix(e.name,".odin") || strings.has_suffix(e.name,"_test.odin") do continue
        bytes,read:=os.read_entire_file(e.fullpath,context.temp_allocator)
        if !testing.expect(t,read==nil,e.name) do continue
        text:=string(bytes)
        testing.expectf(t,!strings.contains(text,"time.now()"),"%s reads the wall clock directly; use store_now",e.name)
        lines:=strings.split(text,"\n")
        for i:=0;i<len(lines);i+=1 {
            line:=lines[i]
            at:=strings.index(line," :: proc(")
            if at<=0 || strings.has_prefix(line," ") || strings.has_prefix(line,"\t") do continue
            name:=line[:at]
            sig:=line;j:=i
            for !strings.has_suffix(strings.trim_space(lines[j]),"{") && j+1<len(lines) && j<i+6 { j+=1; sig=strings.concatenate({sig,lines[j]}) }
            compact,_:=strings.remove_all(sig," ")
            if !strings.contains(compact,"s:^Store") || !strings.contains(compact,"now:i64") do continue
            allowed:=false
            for a in CLOCK_SOURCE_ALLOWLIST do if a==name do allowed=true
            if allowed do continue
            body:=""
            for k:=j+1;k<len(lines) && lines[k]!="}";k+=1 do body=strings.concatenate({body,lines[k],"\n"})
            checked+=1
            testing.expectf(t,strings.contains(body,"store_now(s,now)"),"%s:%s takes a time but does not derive it from store_now(s,now)",e.name,name)
        }
    }
    testing.expectf(t,checked>0,"the guard found the time-taking procs (%d)",checked)
}
