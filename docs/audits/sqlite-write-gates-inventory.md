# SQLite repository write gate inventory (in progress)

This working inventory supports task `task_18eaa40a206c037e`. It is not a
completion claim. It enumerates named procedures containing mutation SQL or
calling such procedures, including SQL-producing helpers. SQL constants are
associated with their consumers. Startup migrations and dedicated-connection
operations remain listed for explicit review. Generic execution helpers and
SQL assembled entirely at runtime need manual review before final submission.

The source scan is conservative: a direct gate says only that the procedure
enters the gate; it does not prove all callers respect lock order. PENDING
entries need analysis and either a gate, an enforced UoW precondition, or a
documented dedicated/startup-only exemption. Ordinary agent saves and bridge
runtime writes still need the coordinator-approved generation-fencing refactor.

| File and current line | Procedure | Current status |
| --- | --- | --- |
| acp_chat.odin:20 | `content_save_assistant_turn_sqlite` | PENDING caller/gate audit |
| action_repo_sqlite.odin:216 | `actions_save` | direct gate |
| action_repo_sqlite.odin:225 | `actions_trigger_save` | direct gate |
| action_repo_sqlite.odin:234 | `actions_run_insert` | direct gate |
| action_repo_sqlite.odin:348 | `actions_set_last_spawned` | direct gate |
| action_repo_sqlite.odin:354 | `actions_trigger_delete` | direct gate |
| action_repo_sqlite.odin:361 | `actions_delete_action` | direct gate |
| action_repo_sqlite.odin:377 | `actions_rules_replace` | direct gate |
| action_repo_sqlite.odin:395 | `actions_run_transition` | direct gate |
| action_repo_sqlite.odin:426 | `actions_runs_prune` | direct gate |
| agent_repo_sqlite.odin:19 | `agent_delete_instance_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:33 | `agent_next_title_counter_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:51 | `agent_save_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:96 | `agent_save_support_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:130 | `agent_delete_support_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:148 | `agent_save_instance_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:152 | `agent_save_instance_guarded_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:156 | `agent_save_instance_sqlite_impl` | guarded generation saves only; ordinary saves PENDING runtime refactor |
| agent_repo_sqlite.odin:327 | `agent_touch_user_activity_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:342 | `agent_set_stop_reason_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:365 | `agent_update_token_usage_sqlite` | PENDING caller/gate audit |
| agent_repo_sqlite.odin:382 | `agent_add_token_totals_sqlite` | PENDING caller/gate audit |
| agent_write_repo_sqlite.odin:14 | `agent_write_insert_sqlite` | PENDING caller/gate audit |
| artifact_bounded.odin:26 | `content_update_artifact_metadata_sqlite` | PENDING caller/gate audit |
| attention_repo_sqlite.odin:60 | `attention_card_insert_if_absent_sqlite` | PENDING caller/gate audit |
| attention_repo_sqlite.odin:83 | `attention_card_compare_and_set_sqlite` | PENDING caller/gate audit |
| billing_repo_sqlite.odin:52 | `new_billing_repository` | PENDING caller/gate audit |
| billing_repo_sqlite.odin:101 | `billing_refresh_parameters` | PENDING caller/gate audit |
| billing_repo_sqlite.odin:113 | `billing_ensure_account` | PENDING caller/gate audit |
| billing_repo_sqlite.odin:166 | `billing_reserve_checkout` | PENDING caller/gate audit |
| billing_repo_sqlite.odin:195 | `billing_finish_checkout` | PENDING caller/gate audit |
| billing_repo_sqlite.odin:202 | `billing_apply_event` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:399 | `bot_insert_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:458 | `bot_set_instance_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:474 | `bot_delete_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:532 | `binding_revoke_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:543 | `pairing_insert_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:567 | `pairing_delete_for_owner_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:578 | `message_insert_outbound_sqlite` | direct gate |
| bot_repo_sqlite.odin:622 | `message_set_send_result_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:671 | `messages_mark_replied_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:687 | `messages_purge_binding_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:706 | `messages_purge_older_than_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:750 | `delivery_insert_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:799 | `attempt_insert_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:885 | `delivery_update_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:916 | `attempt_update_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:984 | `placement_replace_sqlite` | direct gate |
| bot_repo_sqlite.odin:1033 | `binding_activate_sqlite` | direct gate |
| bot_repo_sqlite.odin:1097 | `inbound_store_batch_sqlite` | direct gate |
| bot_repo_sqlite.odin:1167 | `messages_mark_read_sqlite` | direct gate |
| bot_repo_sqlite.odin:1197 | `pairing_consume_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:1251 | `binding_set_reengage_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:1263 | `push_events_insert_sqlite` | direct gate |
| bot_repo_sqlite.odin:1360 | `push_batch_commit_sqlite` | direct gate |
| bot_repo_sqlite.odin:1435 | `push_events_purge_processed_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:1443 | `messages_mark_replied_binding_sqlite` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:1485 | `bot_repo_insert_attachment` | PENDING caller/gate audit |
| bot_repo_sqlite.odin:1563 | `attachment_store_artifact_sqlite` | direct gate |
| bot_repo_sqlite.odin:1591 | `attachment_set_state_sqlite` | PENDING caller/gate audit |
| bot_web_sqlite.odin:9 | `web_message_store_sqlite` | check shared web transaction wrapper |
| bridge_log_repo_sqlite.odin:46 | `bridge_log_insert_batch_sqlite` | PENDING caller/gate audit |
| bridge_log_repo_sqlite.odin:84 | `bridge_log_cap_bridge_sqlite` | PENDING caller/gate audit |
| bridge_log_repo_sqlite.odin:102 | `bridge_log_prune_before_sqlite` | PENDING caller/gate audit |
| bridge_log_repo_sqlite.odin:145 | `bridge_log_delete_by_bridge_sqlite` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:10 | `bridge_create_limited_sqlite` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:27 | `bridge_create_limited_on` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:77 | `bridge_sunset_on` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:109 | `bridge_drop_sunset_receipt` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:115 | `bridge_delete_pending_restoring_sunset_sqlite` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:128 | `bridge_delete_pending_restoring_sunset_on` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:237 | `bridge_reconcile_plan_sqlite` | PENDING caller/gate audit |
| bridge_plan_repo_sqlite.odin:247 | `bridge_reconcile_plan_on` | PENDING caller/gate audit |
| bridge_repo_sqlite.odin:78 | `bridge_save_bridge_sqlite` | PENDING caller/gate audit |
| bridge_repo_sqlite.odin:93 | `bridge_update_runtime_sqlite` | PENDING caller/gate audit |
| bridge_repo_sqlite.odin:175 | `bridge_delete_pending_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:24 | `bridge_save_token_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:113 | `bridge_revoke_token_family_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:124 | `bridge_revoke_family_with_receipts_on` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:138 | `bridge_revoke_token_family_on` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:155 | `bridge_revoke_token_family_in_scope_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:174 | `bridge_revoke_tokens_for_bridge_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:187 | `bridge_revoke_with_receipts_on` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:204 | `bridge_revoke_tokens_for_bridge_on` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:219 | `bridge_mark_token_used_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:245 | `bridge_regrant_atomic_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:260 | `bridge_regrant_on` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:303 | `bridge_insert_token_on` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:335 | `bridge_mark_token_rotated_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:366 | `bridge_commit_enrollment_sqlite` | PENDING caller/gate audit |
| bridge_token_repo_sqlite.odin:388 | `bridge_commit_enrollment_on` | PENDING caller/gate audit |
| card_repo_sqlite.odin:106 | `card_create_sqlite` | PENDING caller/gate audit |
| card_repo_sqlite.odin:188 | `card_update_status_sqlite` | PENDING caller/gate audit |
| card_repo_sqlite.odin:210 | `card_update_sqlite` | PENDING caller/gate audit |
| card_repo_sqlite.odin:263 | `card_delete_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:19 | `content_save_memory_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:34 | `content_save_conversation_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:90 | `content_save_message_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:92 | `content_update_message_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:186 | `content_mark_messages_read_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:212 | `content_save_artifact_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:341 | `content_delete_artifact_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:343 | `content_save_template_sqlite` | PENDING caller/gate audit |
| content_repo_sqlite.odin:346 | `content_delete_template_sqlite` | PENDING caller/gate audit |
| conversation_launch_preferences.odin:16 | `launch_preferences_save_sqlite` | PENDING caller/gate audit |
| event_outbox_repo.odin:37 | `outbox_append` | PENDING caller/gate audit |
| event_outbox_repo.odin:74 | `outbox_mark` | PENDING caller/gate audit |
| event_outbox_repo.odin:92 | `outbox_prune` | PENDING caller/gate audit |
| event_outbox_repo.odin:102 | `outbox_next_version` | PENDING caller/gate audit |
| event_outbox_repo.odin:113 | `outbox_open_topic` | PENDING caller/gate audit |
| event_outbox_repo.odin:137 | `outbox_resolve_topic` | PENDING caller/gate audit |
| event_subscription_repo.odin:53 | `subscription_put` | PENDING caller/gate audit |
| event_subscription_repo.odin:116 | `subscription_remove` | PENDING caller/gate audit |
| event_subscription_repo.odin:129 | `subscription_delivered` | PENDING caller/gate audit |
| event_subscription_repo.odin:250 | `subscription_queue_delete` | PENDING caller/gate audit |
| event_subscription_repo.odin:261 | `subscription_prune` | PENDING caller/gate audit |
| event_subscription_repo.odin:281 | `subscription_trim_receipts` | PENDING caller/gate audit |
| event_subscription_repo.odin:292 | `subscription_mark_delivery` | PENDING caller/gate audit |
| event_subscription_repo.odin:342 | `subscription_deleted` | PENDING caller/gate audit |
| experiment_repo_sqlite.odin:24 | `experiment_set_sqlite` | direct gate |
| external_identity.odin:40 | `user_resolve_external_sqlite` | direct gate |
| external_identity.odin:125 | `user_link_external_sqlite` | direct gate |
| external_identity.odin:162 | `user_unlink_external_sqlite` | direct gate |
| external_identity.odin:178 | `user_set_status_sqlite` | direct gate |
| fts_repair.odin:54 | `repair_fts_indexes` | PENDING caller/gate audit |
| fts_repair.odin:101 | `fts_rebuild_one` | PENDING caller/gate audit |
| fts_repair.odin:132 | `step_write_healing` | PENDING caller/gate audit |
| instance_reconfiguration_repo.odin:27 | `instance_reconfiguration_begin_sqlite` | PENDING caller/gate audit |
| instance_reconfiguration_repo.odin:31 | `instance_reconfiguration_advance_sqlite` | PENDING caller/gate audit |
| instance_reconfiguration_repo.odin:38 | `instance_reconfiguration_write_sqlite` | PENDING caller/gate audit |
| instance_reconfiguration_repo.odin:55 | `instance_reconfiguration_begin_impl` | PENDING caller/gate audit |
| instance_reconfiguration_repo.odin:87 | `instance_reconfiguration_advance_impl` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:62 | `issue_save_sqlite` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:213 | `issue_update_sqlite` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:249 | `issue_delete_sqlite` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:285 | `issue_comment_save_sqlite` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:339 | `issue_comment_delete_sqlite` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:372 | `issue_vote_save_sqlite` | PENDING caller/gate audit |
| issue_repo_sqlite.odin:403 | `issue_vote_remove_sqlite` | PENDING caller/gate audit |
| lsp_server_config_repo_sqlite.odin:41 | `lsp_server_config_upsert_sqlite` | PENDING caller/gate audit |
| lsp_server_config_repo_sqlite.odin:118 | `lsp_server_config_delete_sqlite` | PENDING caller/gate audit |
| mcp_mutations.odin:31 | `mcp_receipt_put` | PENDING caller/gate audit |
| mcp_mutations.odin:52 | `mcp_runtime_receipt_update` | PENDING caller/gate audit |
| mcp_repo_sqlite.odin:30 | `mcp_cleanup` | PENDING caller/gate audit |
| mcp_repo_sqlite.odin:89 | `mcp_put_sqlite` | PENDING caller/gate audit |
| mcp_repo_sqlite.odin:100 | `mcp_remove_sqlite` | PENDING caller/gate audit |
| migrations.odin:1005 | `run_migrations` | PENDING caller/gate audit |
| migrations.odin:1889 | `mark_migration_applied` | PENDING caller/gate audit |
| migrations.odin:2013 | `upgrade_memory_scope_lists_schema` | PENDING caller/gate audit |
| migrations.odin:2078 | `upgrade_memory_description_schema` | PENDING caller/gate audit |
| migrations.odin:2221 | `upgrade_task_v2_schema` | PENDING caller/gate audit |
| mixed_work_repo_sqlite.odin:25 | `insert_work_dependency_sqlite` | PENDING caller/gate audit |
| mixed_work_repo_sqlite.odin:80 | `insert_work_input_receipt_sqlite` | PENDING caller/gate audit |
| mixed_work_repo_sqlite.odin:153 | `append_work_scope_decision_sqlite` | PENDING caller/gate audit |
| mixed_work_repo_sqlite.odin:190 | `remove_work_dependency_sqlite` | PENDING caller/gate audit |
| mixed_work_repo_sqlite.odin:216 | `complete_work_chain_sqlite` | PENDING caller/gate audit |
| multi_question.odin:9 | `content_answer_question_sqlite` | PENDING caller/gate audit |
| pipeline_delivery_repo_sqlite.odin:88 | `pipeline_insert` | UoW required by pipeline_prepare |
| pipeline_delivery_repo_sqlite.odin:111 | `pipeline_transition` | UoW required by pipeline_prepare |
| pipeline_delivery_repo_sqlite.odin:207 | `pipeline_prune` | UoW required by pipeline_prepare |
| project_repo_sqlite.odin:42 | `project_save_sqlite` | direct gate |
| project_repo_sqlite.odin:57 | `project_save_bridge_path_sqlite` | direct gate |
| project_repo_sqlite.odin:86 | `project_delete_bridge_path_sqlite` | direct gate |
| provider_extension_commands.odin:4 | `provider_extension_command_create_sqlite` | PENDING caller/gate audit |
| provider_extension_commands.odin:42 | `provider_extension_command_save_sqlite` | PENDING caller/gate audit |
| provider_profiles.odin:87 | `bridge_provider_profiles_reconcile_sqlite` | PENDING caller/gate audit |
| provider_repo_sqlite.odin:35 | `bridge_provider_status_upsert_sqlite` | PENDING caller/gate audit |
| provider_repo_sqlite.odin:62 | `bridge_provider_setting_upsert_sqlite` | PENDING caller/gate audit |
| provider_repo_sqlite.odin:214 | `bridge_provider_models_upsert_sqlite` | PENDING caller/gate audit |
| provider_repo_sqlite.odin:262 | `set_provider_transport_sqlite` | PENDING caller/gate audit |
| push_repo_sqlite.odin:39 | `push_upsert_by_endpoint_sqlite` | direct gate |
| push_repo_sqlite.odin:120 | `push_delete_by_endpoint_sqlite` | direct gate |
| push_repo_sqlite.odin:145 | `push_delete_by_id_sqlite` | direct gate |
| session_repo_sqlite.odin:57 | `session_create_sqlite` | direct gate |
| session_repo_sqlite.odin:84 | `session_touch_sqlite` | direct gate |
| session_repo_sqlite.odin:96 | `session_delete_sqlite` | direct gate |
| session_repo_sqlite.odin:116 | `session_purge_expired_sqlite` | direct gate |
| session_repo_sqlite.odin:138 | `session_delete_user_sqlite` | delegates to gated delete_user_sessions_sqlite |
| session_repo_sqlite.odin:145 | `delete_user_sessions_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:88 | `shell_session_upsert_sqlite` | PENDING caller/gate audit |
| shell_session_repo_sqlite.odin:556 | `shell_session_set_server_port_sqlite` | PENDING caller/gate audit |
| shell_session_repo_sqlite.odin:577 | `shell_session_delete_sqlite` | PENDING caller/gate audit |
| shell_session_repo_sqlite.odin:615 | `shell_session_delete_terminal_before_sqlite` | PENDING caller/gate audit |
| shell_session_repo_sqlite.odin:626 | `shell_session_delete_terminal_before_owners_sqlite` | PENDING caller/gate audit |
| shell_session_repo_sqlite.odin:831 | `shell_session_set_kill_requested_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:163 | `taskchain_save_chain_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:174 | `task_save_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:216 | `task_comment_save_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:335 | `taskchain_save_member_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:346 | `taskchain_remove_member_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:384 | `taskchain_save_dependency_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:395 | `taskchain_remove_dependency_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:418 | `taskchain_save_directory_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:463 | `taskchain_remove_directory_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:502 | `taskchain_upsert_fleet_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:525 | `taskchain_ensure_fleet_sqlite` | PENDING caller/gate audit |
| taskchain_repo_sqlite.odin:562 | `taskchain_delete_fleet_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:61 | `taskchain_take_boot_regate_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:89 | `task_event_append_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:175 | `task_attempt_save_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:215 | `task_attempt_facet_save_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:267 | `task_lease_save_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:328 | `task_lease_delete_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:358 | `task_review_save_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:403 | `chain_summary_save_sqlite` | PENDING caller/gate audit |
| taskv2_repo_sqlite.odin:430 | `workflow_definition_save_sqlite` | PENDING caller/gate audit |
| user_repo_sqlite.odin:38 | `user_save_sqlite` | direct gate |
| vault_directory_repo_sqlite.odin:72 | `vault_consume_request_nonce_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:199 | `insert_device_on` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:298 | `insert_log_on` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:313 | `vault_mark_retired_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:385 | `vault_register_pending_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:465 | `vault_delete_pending_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:484 | `vault_touch_last_seen_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:509 | `insert_epoch_on` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:522 | `upsert_wrap_on` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:535 | `vault_create_genesis_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:593 | `vault_commit_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:737 | `vault_schedule_reset_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:769 | `vault_cancel_reset_sqlite` | PENDING caller/gate audit |
| vault_directory_repo_sqlite.odin:808 | `vault_execute_reset_sqlite` | PENDING caller/gate audit |
| workflow_run_repo_sqlite.odin:29 | `insert_workflow_run_sqlite` | PENDING caller/gate audit |
| workflow_run_repo_sqlite.odin:53 | `update_workflow_run_sqlite` | PENDING caller/gate audit |
| workflow_run_repo_sqlite.odin:142 | `insert_workflow_execution_sqlite` | PENDING caller/gate audit |
| workflow_run_repo_sqlite.odin:163 | `update_workflow_execution_sqlite` | PENDING caller/gate audit |
| workflow_run_repo_sqlite.odin:231 | `insert_workflow_stage_execution_sqlite` | PENDING caller/gate audit |
| workflow_run_repo_sqlite.odin:281 | `append_workflow_run_event_sqlite` | PENDING caller/gate audit |
