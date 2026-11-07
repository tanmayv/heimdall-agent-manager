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
// R3 one-shot import. Freeze checks blockers, selects and freezes in ONE
// transaction; blockers return without any write.
Legacy_Migration_Freeze_Now :: proc(ctx:rawptr, selection:domain.Legacy_Migration_Selection) -> (domain.Legacy_Source_Fence,[]domain.Legacy_Migration_Blocker,domain.Domain_Error)
Legacy_Migration_Blockers :: proc(ctx:rawptr, chain:string) -> ([]domain.Legacy_Migration_Blocker,domain.Domain_Error)
Legacy_Migration_Export_Proc :: proc(ctx:rawptr, account,chain,migration:string) -> (domain.Legacy_Migration_Export,domain.Domain_Error)
// Registers owner routing and marks the migration imported atomically. Callers
// verify the owner's signed import receipt first.
Legacy_Migration_Cutover :: proc(ctx:rawptr, account,chain,migration,manifest_digest,receipt_digest:string, route:domain.Owner_Registry_Record) -> (bool,domain.Domain_Error)
Legacy_Migration_Get :: proc(ctx:rawptr, account,migration:string) -> (domain.Legacy_Source_Fence,bool,domain.Domain_Error)
// Aborts a selected or frozen (never imported) migration for the account owner.
Legacy_Migration_Abort :: proc(ctx:rawptr, account,chain,migration:string) -> (bool,domain.Domain_Error)
Legacy_Migration_Aborted :: proc(ctx:rawptr, account,migration:string) -> (string,string,bool,domain.Domain_Error)
