#+private file
package sqlite

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider "odin_test:hub/service/provider"


@(test)
test_bridge_models_report_rejects_unsolicited_or_malformed_data :: proc(t: ^testing.T) {
	svc := provider.new_provider_service(nil)
	defer delete(svc.test_runs)
	item := provider.Model_Discovery_Item{provider="codex",models_state="success",has_snapshot=true,models_source="codex_app_server",models_checked_at="now",models_attempted_at="now"}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Validation_Failed)
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{"claude"},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Forbidden)
	item.models=[]provider.Discovered_Model{{model_id="--bad",label="bad"}}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{"codex"},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Validation_Failed)
	item.models=[]provider.Discovered_Model{{model_id="same"},{model_id="same"}}
	testing.expect_value(t,provider.apply_model_discovery_report(&svc,"a",[]string{"codex"},[]provider.Model_Discovery_Item{item}).code,domain.Error_Code.Validation_Failed)
	testing.expect(t,!provider.model_id_valid(strings.repeat("x",257,context.temp_allocator)))
}
