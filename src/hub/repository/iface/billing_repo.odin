package iface

import domain "odin_test:hub/domain"

Billing_Repository :: struct {
	ctx: rawptr,
	get_account: proc(ctx: rawptr, user_id, now: string) -> (domain.Account_Billing, domain.Domain_Error),
	list_plans: proc(ctx: rawptr) -> ([]domain.Billing_Plan, domain.Domain_Error),
	reserve_checkout: proc(ctx: rawptr, checkout: domain.Billing_Checkout, now: string) -> (domain.Billing_Checkout, bool, domain.Domain_Error),
	finish_checkout: proc(ctx: rawptr, checkout: domain.Billing_Checkout) -> domain.Domain_Error,
	apply_event: proc(ctx: rawptr, event: domain.Billing_Event, now: string) -> domain.Domain_Error,
}
