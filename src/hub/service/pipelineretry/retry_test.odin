package pipelineretry
import "core:testing"
import "core:time"
@(test)
test_stage_throttling :: proc(t:^testing.T) {
 s:State
 now:=time.Tick{_nsec=100}
 emit,total,hidden:=record(&s,.Connect,now)
 testing.expect(t,emit && total==1 && hidden==0)
 for _ in 0..<99 {
  emit,_,_=record(&s,.Connect,now)
  testing.expect(t,!emit)
 }
 emit,_,_=record(&s,.Publish,now)
 testing.expect(t,emit,"independent stages must not hide each other")
 emit,total,hidden=record(&s,.Connect,time.Tick{_nsec=now._nsec+i64(30*time.Second)})
 testing.expect(t,emit && total==101 && hidden==99)
 testing.expect_value(t,s.stages[.Connect].failures,u64(101))
}
@(test)
test_jitter_bounds :: proc(t:^testing.T) {
 for base in ([]time.Duration{time.Millisecond,100*time.Millisecond,time.Second,5*time.Second,10*time.Second}) {
  cap:=min(base,5*time.Second)
  for entropy:u64=0;entropy<1000;entropy+=1 {
   delay:=jitter(base,entropy*1234567)
   testing.expect(t,delay>=cap-cap/4 && delay<=cap)
  }
 }
 testing.expect(t,jitter(time.Second,1)!=jitter(time.Second,1234567))
}
