package iface

import domain "odin_test:hub/domain"

Legacy_Migration_Select :: proc(ctx:rawptr, selection:domain.Legacy_Migration_Selection) -> domain.Domain_Error
Legacy_Source_Get :: proc(ctx:rawptr, account,chain:string) -> (domain.Legacy_Source_Fence,bool,domain.Domain_Error)
// Prepare is inside the task mutation's UoW, BEFORE COMMIT, never in a
// post-commit sender. An unknown/lost reply leaves the effect outstanding.
Legacy_Effect_Prepare :: proc(ctx:rawptr, effect:domain.Legacy_Source_Effect) -> (i64,domain.Domain_Error)
// Freeze requires separately authenticated generation-bound physical drain
// evidence. It is not a query for an empty lease table.
Legacy_Source_Freeze :: proc(ctx:rawptr, account,chain,migration,selection_digest,quiescence_digest:string, revision,generation:i64) -> domain.Domain_Error
