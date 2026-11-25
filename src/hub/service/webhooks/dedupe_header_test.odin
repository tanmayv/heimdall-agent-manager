package webhooks
import "core:strings"
import "core:testing"
@(test)
test_dedupe_header_tokens :: proc(t:^testing.T) {
 for name in ([]string{"Idempotency-Key","X-GitHub-Delivery","Svix-Id","X-Request-Id","!#$%&'*+-.^_`|~",strings.repeat("A",64,context.temp_allocator)}) do testing.expect(t,dedupe_header_valid(name),name)
 for name in ([]string{""," X-Id","X Id","X:Id","X/Id","X\r\nInjected","é",strings.repeat("A",65,context.temp_allocator)}) do testing.expect(t,!dedupe_header_valid(name),name)
}

@(test)
test_dedupe_header_rejects_credentials :: proc(t:^testing.T) {
 for name in ([]string{"Authorization","authorization","AUTHORIZATION","Proxy-Authorization","pRoXy-AuThOrIzAtIoN","Cookie","COOKIE","Set-Cookie","sEt-CoOkIe","X-Api-Key","x-API-key"}) {
  testing.expect(t,!dedupe_header_valid(name),name)
 }
 // Other tokens remain generic; the policy excludes only credential headers.
 for name in ([]string{"Content-Type","Content-Length","Host","X-Authorization-Event","X-GitHub-Delivery","Svix-Id","X-Request-Id"}) do testing.expect(t,dedupe_header_valid(name),name)
}
