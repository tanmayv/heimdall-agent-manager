package actions
import "core:time"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import domain "odin_test:hub/domain"

// One bounded transaction per minute: age128 rows + cap128 rows each for
// at most16 actions, using an indexed round-robin rowid cursor.
sweep_history :: proc(s:^Service,now:time.Time)->domain.Domain_Error {
 uow,ok,err:=iface.unit_of_work_begin(s.factory)
 if !ok do return err
 defer if uow.ctx!=nil do iface.unit_of_work_rollback(&uow)
 cutoff:=platform.format_rfc3339_utc(time.time_add(now,-30*24*time.Hour))
 err=uow.repos.actions.runs_sweep(uow.repos.actions.ctx,cutoff,128)
 if err.code!=.None do return err
 cursor,e:=uow.repos.actions.runs_cap_page(uow.repos.actions.ctx,s.history_cursor,16)
 if e.code!=.None do return e
 repo:=&uow.repos.pipeline_deliveries
 err=repo.prune(repo.ctx,cutoff)
 if err.code!=.None do return err
 committed,commit_err:=iface.unit_of_work_commit(&uow);uow.ctx=nil
 err=commit_err
 if committed do s.history_cursor=cursor
 return err
}
