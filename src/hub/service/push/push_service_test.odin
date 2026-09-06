package push

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// stub_push_repo is a minimal in-memory Push_Repository for service tests. It
// records the last upserted subscription and a canned outcome so we can assert
// the service's validation + id/timestamp behavior without a database.
stub_push_repo :: struct {
	last_upsert: domain.Push_Subscription,
	upsert_called: bool,
}

@(private = "file")
stub_upsert :: proc(ctx: rawptr, sub: domain.Push_Subscription) -> (domain.Push_Subscription, bool, domain.Domain_Error) {
	stub := (^stub_push_repo)(ctx)
	stub.last_upsert = sub
	stub.upsert_called = true
	return sub, true, domain.Domain_Error{}
}

@(private = "file")
stub_list :: proc(ctx: rawptr, owner: domain.User_ID) -> ([]domain.Push_Subscription, domain.Domain_Error) {
	return nil, domain.Domain_Error{}
}

@(private = "file")
stub_delete_by_endpoint :: proc(ctx: rawptr, owner: domain.User_ID, endpoint: string) -> (bool, domain.Domain_Error) {
	return true, domain.Domain_Error{}
}

@(private = "file")
stub_delete_by_id :: proc(ctx: rawptr, id: domain.Push_Subscription_ID) -> (bool, domain.Domain_Error) {
	return true, domain.Domain_Error{}
}

@(private = "file")
new_stub_service :: proc(stub: ^stub_push_repo, repo: ^iface.Push_Repository, clock: ^platform.Clock, ids: ^platform.ID_Generator) -> Push_Service {
	repo^ = iface.Push_Repository{
		ctx = rawptr(stub),
		upsert_by_endpoint = stub_upsert,
		list_by_owner = stub_list,
		delete_by_endpoint = stub_delete_by_endpoint,
		delete_by_id = stub_delete_by_id,
	}
	clock^ = platform.real_clock()
	ids^ = platform.real_id_generator()
	return new_push_service(repo, clock, ids)
}

@(test)
save_subscription_generates_id_and_timestamps :: proc(t: ^testing.T) {
	stub: stub_push_repo
	repo: iface.Push_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := new_stub_service(&stub, &repo, &clock, &ids)

	saved, ok, err := save_subscription(&service, Save_Subscription_Input{
		owner_user_id = "usr_1",
		endpoint = "https://web.push.apple.com/xyz",
		p256dh = "p256",
		auth = "auth",
	})
	testing.expect(t, ok)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect(t, stub.upsert_called)
	// The service mints a psub_ id and stamps created_at/updated_at.
	testing.expect(t, len(string(saved.id)) > len("psub_"))
	testing.expect(t, saved.created_at != "")
	testing.expect_value(t, saved.created_at, saved.updated_at)
	testing.expect_value(t, saved.endpoint, "https://web.push.apple.com/xyz")
}

@(test)
save_subscription_trims_and_validates :: proc(t: ^testing.T) {
	stub: stub_push_repo
	repo: iface.Push_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := new_stub_service(&stub, &repo, &clock, &ids)

	// Missing keys -> validation error, repo not touched.
	_, ok, err := save_subscription(&service, Save_Subscription_Input{
		owner_user_id = "usr_1",
		endpoint = "https://x/y",
		p256dh = "  ",
		auth = "",
	})
	testing.expect(t, !ok)
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)
	testing.expect(t, !stub.upsert_called)

	// Missing owner -> unauthenticated.
	_, ok2, err2 := save_subscription(&service, Save_Subscription_Input{
		owner_user_id = "",
		endpoint = "https://x/y",
		p256dh = "p",
		auth = "a",
	})
	testing.expect(t, !ok2)
	testing.expect_value(t, err2.code, domain.Error_Code.Unauthenticated)
}

@(test)
delete_subscription_requires_endpoint :: proc(t: ^testing.T) {
	stub: stub_push_repo
	repo: iface.Push_Repository
	clock: platform.Clock
	ids: platform.ID_Generator
	service := new_stub_service(&stub, &repo, &clock, &ids)

	_, err := delete_subscription(&service, "usr_1", "   ")
	testing.expect_value(t, err.code, domain.Error_Code.Validation_Failed)

	deleted, err2 := delete_subscription(&service, "usr_1", "https://x/y")
	testing.expect(t, deleted)
	testing.expect_value(t, err2.code, domain.Error_Code.None)
}
