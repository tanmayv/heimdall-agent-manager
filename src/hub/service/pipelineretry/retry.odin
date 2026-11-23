// Fixed-size stage diagnostics: no unbounded map or per-failure allocation.
// State may be shared by workers; logging and counters are protected together.
package pipelineretry
import "core:fmt"
import "core:sync"
import "core:time"
Stage :: enum { Connect, Stream, Consumer, Bind, Read, Publish, Commit, Headers, Reconcile, Advisory, Retention }
Counter :: struct { failures, suppressed: u64, last_log: time.Tick, logged: bool }
State :: struct { mutex: sync.Mutex, stages: [Stage]Counter }
record :: proc(s:^State,stage:Stage,now:time.Tick)->(emit:bool,total,suppressed:u64) {
 sync.mutex_lock(&s.mutex);defer sync.mutex_unlock(&s.mutex)
 c:=&s.stages[stage]
 c.failures+=1
 if !c.logged || now._nsec-c.last_log._nsec>=i64(30*time.Second) {
  emit=true;total=c.failures;suppressed=c.suppressed
  c.suppressed=0;c.last_log=now;c.logged=true
 } else {c.suppressed+=1}
 return
}
failed :: proc(s:^State,component:string,stage:Stage,status:i32=0,jetstream:i32=0)->bool {
 emit,total,suppressed:=record(s,stage,time.tick_now())
 if emit do fmt.eprintf("%s: retry stage=%v status=%d jetstream=%d failures=%d suppressed=%d\n",component,stage,status,jetstream,total,suppressed)
 return false
}
// Equal jitter: 75%-100% of an exponentially increasing, capped delay.
// Entropy is monotonic nanoseconds; no global random-generator lock/state.
jitter :: proc(delay:time.Duration,entropy:u64)->time.Duration {
 cap:=clamp(delay,time.Millisecond,5*time.Second)
 span:=max(cap/4,time.Duration(1))
 return cap-span+time.Duration(entropy%u64(span+1))
}
