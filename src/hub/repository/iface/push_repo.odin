package iface

import domain "odin_test:hub/domain"

// Push_Subscription_Upsert_Proc inserts a subscription or, when a row with the
// same endpoint already exists, replaces its keys (p256dh/auth) and owner. The
// returned subscription carries the persisted id.
Push_Subscription_Upsert_Proc :: proc(ctx: rawptr, sub: domain.Push_Subscription) -> (domain.Push_Subscription, bool, domain.Domain_Error)
Push_Subscription_List_By_Owner_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID) -> ([]domain.Push_Subscription, domain.Domain_Error)
Push_Subscription_Delete_By_Endpoint_Proc :: proc(ctx: rawptr, owner_user_id: domain.User_ID, endpoint: string) -> (bool, domain.Domain_Error)
Push_Subscription_Delete_By_ID_Proc :: proc(ctx: rawptr, id: domain.Push_Subscription_ID) -> (bool, domain.Domain_Error)

Push_Repository :: struct {
	ctx:                rawptr,
	upsert_by_endpoint: Push_Subscription_Upsert_Proc,
	list_by_owner:      Push_Subscription_List_By_Owner_Proc,
	delete_by_endpoint: Push_Subscription_Delete_By_Endpoint_Proc,
	delete_by_id:       Push_Subscription_Delete_By_ID_Proc,
}

push_subscription_upsert :: proc(repo: ^Push_Repository, sub: domain.Push_Subscription) -> (domain.Push_Subscription, bool, domain.Domain_Error) {
	if repo == nil || repo.upsert_by_endpoint == nil {
		return domain.Push_Subscription{}, false, domain.domain_error(.Internal_Error, "push repository is not configured")
	}
	return repo.upsert_by_endpoint(repo.ctx, sub)
}

push_subscription_list_by_owner :: proc(repo: ^Push_Repository, owner_user_id: domain.User_ID) -> ([]domain.Push_Subscription, domain.Domain_Error) {
	if repo == nil || repo.list_by_owner == nil {
		return nil, domain.domain_error(.Internal_Error, "push repository is not configured")
	}
	return repo.list_by_owner(repo.ctx, owner_user_id)
}

push_subscription_delete_by_endpoint :: proc(repo: ^Push_Repository, owner_user_id: domain.User_ID, endpoint: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_by_endpoint == nil {
		return false, domain.domain_error(.Internal_Error, "push repository is not configured")
	}
	return repo.delete_by_endpoint(repo.ctx, owner_user_id, endpoint)
}

push_subscription_delete_by_id :: proc(repo: ^Push_Repository, id: domain.Push_Subscription_ID) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.delete_by_id == nil {
		return false, domain.domain_error(.Internal_Error, "push repository is not configured")
	}
	return repo.delete_by_id(repo.ctx, id)
}
