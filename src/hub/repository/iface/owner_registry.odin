package iface

import domain "odin_test:hub/domain"

Owner_Registry_Publish :: proc(ctx:rawptr, record:domain.Owner_Registry_Record) -> domain.Domain_Error
Owner_Registry_List :: proc(ctx:rawptr, account,chain,after_chain,after_task:string,limit:int,headers_only:bool) -> ([]domain.Owner_Registry_Record,domain.Domain_Error)
// One row per owner-held chain of the account (chain_id, owner_bridge_id,
// owner_key_id; no titles). chain="" lists every chain, unbounded by page size.
Owner_Registry_Routes :: proc(ctx:rawptr, account,chain:string) -> ([]domain.Owner_Registry_Record,domain.Domain_Error)
