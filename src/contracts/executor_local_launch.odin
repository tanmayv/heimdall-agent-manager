package contracts

// Local device consent is independent of owner/task authority. The exact
// configuration is carried inside encrypted transport, bound by its raw digest.
executor_local_launch_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"principal_id","id"},{"operation_id","id"},{"configuration_digest","hash"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},
    {"key_id","id"},{"signature","signature"},
}
executor_local_configuration_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"instance_id","id"},{"launch_epoch","id"},{"run_count","positive"},
    {"token_generation","hash"},{"configuration_revision","positive"},
    {"executor_incarnation","positive"},{"policy_revision","positive"},
    {"slot_id","id"},{"provider","label"},{"model","label"},{"provider_profile","id"},
    {"directory_id","id"},{"directory_revision","positive"},{"directory_key","hash"},
    {"purpose","executor_local_purpose"},{"spawn_digest","hash"},
}
