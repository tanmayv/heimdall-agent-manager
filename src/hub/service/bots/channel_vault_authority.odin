package bots

import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import placement "odin_test:hub/service/placement"
import project "odin_test:hub/service/project"
import vault "odin_test:lib/vault"

// Public routing metadata only. Compare before and after the volatile exchange:
// replacing a socket, retiring an identity or rotating/resetting the vault
// invalidates output produced under the previous authority.
Channel_Vault_Authority :: struct {
	connection_generation: int,
	device_id, boot_id, vault_id, directory_head: string,
	vault_epoch: u32,
}

channel_vault_authority :: proc(s: ^Bots_Service, owner, bridge_id: string) -> (Channel_Vault_Authority, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	if owner == "" || bridge_id == "" do return {}, bots_detail_error(.Forbidden, "channel_vault_wrong_owner")
	bridge, found, err := iface.bridge_get_bridge(s.bridges, bridge_id)
	defer domain.bridge_destroy(&bridge)
	if err.code != .None do return {}, err
	if !found || bridge.bridge_id != bridge_id do return {}, bots_detail_error(.Not_Found, "channel_vault_bridge_missing")
	ps := bots_placement(s)
	if eligible, reason := placement.bridge_eligible(&ps, bridge, {owner=owner, features={contracts.BRIDGE_FEATURE_BOT_CHANNEL_VAULT_V1}}); !eligible {
		return {}, placement.eligibility_error(&ps, bridge, reason)
	}
	generation := project.bridge_runtime_registry_generation(s.registry, bridge_id)
	identity, live := project.bridge_runtime_registry_unseal_identity(s.registry, bridge_id, context.temp_allocator)
	if !live || generation <= 0 do return {}, bots_detail_error(.Bridge_Offline, "channel_vault_bridge_offline")
	boot, boot_ok := vault.bridge_unseal_key_canonical(bridge_id, identity.public_key, identity.unseal_boot_id, context.temp_allocator)
	device_id, device_ok := vault.device_id_from_sign_pub(identity.identity_public_key, context.temp_allocator)
	if !boot_ok || !device_ok || !vault.verify(identity.identity_sign_alg, identity.identity_public_key, transmute([]byte)boot, identity.unseal_key_signature) {
		return {}, bots_detail_error(.Forbidden, "channel_vault_bridge_identity")
	}
	dir, configured, dir_err := iface.vault_get_directory(s.channel_vault_directory, owner)
	if dir_err.code != .None do return {}, dir_err
	if !configured do return {}, domain.vault_locked_error(bridge_id)
	if dir.user_id != owner || dir.head_hash == "" || dir.current_epoch < 1 || dir.current_epoch > i64(vault.MAX_EPOCH) do return {}, bots_detail_error(.Forbidden, "channel_vault_directory_invalid")
	devices, list_err := iface.vault_list_devices(s.channel_vault_directory, owner)
	if list_err.code != .None do return {}, list_err
	vault_id: string
	approved := false
	for d in devices {
		if d.user_id != owner do continue
		if d.device_id == dir.root_device_id {
			id, valid := vault.vault_id_from_root_sign_pub(d.sign_public_key)
			buf: [vault.VAULT_ID_HEX_CHARS]byte
			if valid do vault_id = strings.clone(vault.vault_id_hex(id, buf[:]), context.temp_allocator)
		}
		if d.device_id == device_id && d.bridge_id == bridge_id && d.kind == "bridge" && d.status == .Approved &&
		   d.retired_at == "" && d.revoked_at == "" && d.sign_alg == identity.identity_sign_alg && d.sign_public_key == identity.identity_public_key {
			approved = true
		}
	}
	if !approved || vault_id == "" do return {}, bots_detail_error(.Forbidden, "channel_vault_device_not_approved")
	if project.bridge_runtime_registry_generation(s.registry, bridge_id) != generation do return {}, bots_detail_error(.Bridge_Offline, "channel_vault_bridge_replaced")
	return {generation, device_id, identity.unseal_boot_id, vault_id, dir.head_hash, u32(dir.current_epoch)}, {}
}
