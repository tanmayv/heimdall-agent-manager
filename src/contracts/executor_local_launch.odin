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

// A draft is native-generated. Device commands bind its immutable revision and
// public configuration; no startup or daemon control secrets cross this schema.
executor_local_draft_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"principal_id","id"},{"operation_id","id"},{"method","executor_draft_method"},
    {"draft_id","hash"},{"draft_revision","positive"},{"configuration_digest","hash"},
    {"issued_ms","positive"},{"request_expires_ms","positive"},
    {"key_id","id"},{"signature","signature"},
}

// Local routing has no fabricated owner/chain/task/lease or task grant.
executor_local_relay_fields := [?]Owner_Field{
    {"protocol_version","version"},{"bridge_id","id"},{"request_id","id"},
    {"expires_ms","positive"},{"envelope","required_cipher"},
}
executor_local_result_fields := [?]Owner_Field{
    {"protocol_version","version"},{"account_id","id"},{"executor_bridge_id","id"},
    {"principal_id","id"},{"operation_id","id"},{"request_id","id"},
    {"request_digest","hash"},{"result_digest","hash"},{"issued_ms","positive"},
    {"request_expires_ms","positive"},{"key_id","id"},{"signature","signature"},
}
executor_local_bundle_fields := [?]Owner_Field{{"receipt","document"},{"body","document"}}
// Local transport carries an already signed record, never operator authority.
executor_operator_import_fields := [?]Owner_Field{{"kind","label"},{"document","document"}}
