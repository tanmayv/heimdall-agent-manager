package actions
import "core:time"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"

// One bounded transaction per minute, independent of action and NATS activity.
sweep_history :: proc(s:^Service,now:time.Time)->domain.Domain_Error {
 uow,ok,err:=iface.unit_of_work_begin(s.factory)
 if !ok do return err
 defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
 cutoff:=platform.format_rfc3339_utc(time.time_add(now,-30*24*time.Hour))
 err=uow.repos.actions.runs_sweep(uow.repos.actions.ctx,cutoff,128)
 if err.code!=.None do return err
 repo:=&uow.repos.pipeline_deliveries
 err=repo.prune(repo.ctx,cutoff)
 if err.code!=.None do return err
 _,err=iface.unit_of_work_commit(&uow);uow.ctx=nil
 return err
}
