package webhooks
import "core:strings"
import "core:testing"
@(test)
test_dedupe_header_tokens :: proc(t:^testing.T) {
 for name in ([]string{"Idempotency-Key","X-GitHub-Delivery","Svix-Id","X-Request-Id","!#$%&'*+-.^_`|~",strings.repeat("A",64,context.temp_allocator)}) do testing.expect(t,dedupe_header_valid(name),name)
 for name in ([]string{""," X-Id","X Id","X:Id","X/Id","X\r\nInjected","é",strings.repeat("A",65,context.temp_allocator)}) do testing.expect(t,!dedupe_header_valid(name),name)
}
