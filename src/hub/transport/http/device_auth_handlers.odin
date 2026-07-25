// HTTP handlers for the device-authorization flow (ELDA-1).
//
// POST /api/v1/device/authorize is PUBLIC (no bearer/trusted-proxy auth): the
// device is not yet authenticated — that is the whole point of the flow. It
// accepts {client, device_label?, os?, app_version?} and returns the
// device-poll contract. All security rests on the unlinkable two-secret codes,
// the per-IP rate limit, and the short TTL.

package http

import "core:fmt"
import "core:strings"
import device_auth "odin_test:hub/service/device_auth"
import domain "odin_test:hub/domain"

Device_Auth_Handlers :: struct {
	service: ^device_auth.Device_Auth_Service,
}

// device_authorize_handler is the public POST /api/v1/device/authorize endpoint.
device_authorize_handler :: proc(ctx: rawptr, req: Request) -> Response {
	handlers := (^Device_Auth_Handlers)(ctx)
	input := device_auth.Authorize_Input{
		client = json_string(req.body, "client"),
		device_label = json_string(req.body, "device_label"),
		os = json_string(req.body, "os"),
		app_version = json_string(req.body, "app_version"),
	}
	xff := header_value(req.headers, "X-Forwarded-For")
	result, ok, err := device_auth.authorize(handlers.service, input, req.remote_addr, xff)
	if !ok do return respond_error(err, req.request_id)
	data := strings.builder_make()
	strings.write_string(&data, "{\"device_code\":\"")
	write_handler_json_string(&data, result.device_code)
	strings.write_string(&data, "\",\"user_code\":\"")
	write_handler_json_string(&data, result.user_code)
	strings.write_string(&data, "\",\"verification_uri\":\"")
	write_handler_json_string(&data, result.verification_uri)
	strings.write_string(&data, fmt.tprintf("\",\"interval\":%d", result.interval))
	strings.write_string(&data, fmt.tprintf(",\"expires_in\":%d", result.expires_in))
	strings.write_string(&data, "}")
	return respond_success(strings.to_string(data), req.request_id, "", 200)
}
