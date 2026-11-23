# SQLite repository write gate inventory

Audit for task `task_18eaa40a206c037e`, requirements revision 2. All request-time
mutation entry points below either enter `tx_repository_enter/leave`, require
an owning UoW, or use an independently opened dedicated connection. Internal SQL
helpers execute under the named entry point gate. Startup migrations are listed
explicitly. SQL constants belong to their consuming entry points; generic SQL
execution primitives have a caller-owned transaction contract.

Gates precede repository mutexes, SQLite db_mutex, and repository-owned BEGINs.
Reentrant calls retain the outer gate; UoW owners reuse their existing gate.
Runtime status/hello/disconnect/heartbeat/vault/features snapshot state under
state_mutex, release it, then persist within an outer UoW opened before the
snapshot. Admission retirement and durable hello commit share that UoW, so an
old operation cannot commit after newer admission. Socket retirement and
lifecycle/event effects run after commit. See `transport/http/bridge_runtime_persist.odin`.

| File and current line | Procedure | Gate status / enforced caller contract |
| --- | --- | --- |
| acp_chat.odin:20 | `content_save_assistant_turn_sqlite` | direct gate |
| action_repo_sqlite.odin:47 | `actions_write` | SQL helper under gated action entry points |
| action_repo_sqlite.odin:216 | `actions_save` | direct gate |
| action_repo_sqlite.odin:225 | `actions_trigger_save` | direct gate |
| action_repo_sqlite.odin:234 | `actions_run_insert` | direct gate |
| action_repo_sqlite.odin:348 | `actions_set_last_spawned` | direct gate |
| action_repo_sqlite.odin:354 | `actions_trigger_delete` | direct gate |
| action_repo_sqlite.odin:361 | `actions_delete_action` | direct gate |
| action_repo_sqlite.odin:377 | `actions_rules_replace` | direct gate |
| action_repo_sqlite.odin:395 | `actions_run_transition` | direct gate |
| action_repo_sqlite.odin:426 | `actions_runs_prune` | direct gate |
| agent_repo_sqlite.odin:19 | `agent_delete_instance_sqlite` | direct gate |
| agent_repo_sqlite.odin:35 | `agent_next_title_counter_sqlite` | direct gate |
| agent_repo_sqlite.odin:55 | `agent_save_sqlite` | direct gate |
| agent_repo_sqlite.odin:102 | `agent_save_support_sqlite` | direct gate |
| agent_repo_sqlite.odin:138 | `agent_delete_support_sqlite` | direct gate |
| agent_repo_sqlite.odin:158 | `agent_save_instance_sqlite` | wrapper delegates to gated agent_save_instance_sqlite_impl |
| agent_repo_sqlite.odin:162 | `agent_save_instance_guarded_sqlite` | wrapper delegates to gated agent_save_instance_sqlite_impl |
| agent_repo_sqlite.odin:166 | `agent_save_instance_sqlite_impl` | direct gate for ordinary and generation-guarded saves; runtime callers release state_mutex |
| agent_repo_sqlite.odin:338 | `agent_touch_user_activity_sqlite` | direct gate |
| agent_repo_sqlite.odin:355 | `agent_set_stop_reason_sqlite` | direct gate |
| agent_repo_sqlite.odin:380 | `agent_update_token_usage_sqlite` | direct gate |
| agent_repo_sqlite.odin:399 | `agent_add_token_totals_sqlite` | direct gate |
| agent_write_repo_sqlite.odin:14 | `agent_write_insert_sqlite` | direct gate |
| artifact_bounded.odin:26 | `content_update_artifact_metadata_sqlite` | direct gate (before repository/db mutex) |
| attention_repo_sqlite.odin:60 | `attention_card_insert_if_absent_sqlite` | direct gate |
| attention_repo_sqlite.odin:86 | `attention_card_compare_and_set_sqlite` | direct gate |
| billing_repo_sqlite.odin:30 | `billing_prepare_on` | SQL prepare helper; no step/mutation itself; dedicated billing caller |
| billing_repo_sqlite.odin:37 | `billing_write` | helper on dedicated Billing_Repo_SQLite.conn |
| billing_repo_sqlite.odin:52 | `new_billing_repository` | dedicated Billing_Repo_SQLite.conn opened by constructor; never aliases main request connection |
| billing_repo_sqlite.odin:101 | `billing_refresh_parameters` | dedicated Billing_Repo_SQLite.conn opened by constructor; never aliases main request connection |
| billing_repo_sqlite.odin:113 | `billing_ensure_account` | dedicated Billing_Repo_SQLite.conn opened by constructor; never aliases main request connection |
| billing_repo_sqlite.odin:166 | `billing_reserve_checkout` | dedicated Billing_Repo_SQLite.conn opened by constructor; never aliases main request connection |
| billing_repo_sqlite.odin:195 | `billing_finish_checkout` | dedicated Billing_Repo_SQLite.conn opened by constructor; never aliases main request connection |
| billing_repo_sqlite.odin:202 | `billing_apply_event` | dedicated Billing_Repo_SQLite.conn opened by constructor; never aliases main request connection |
| bot_repo_sqlite.odin:112 | `bot_repo_write` | SQL helper under gated bot/agent-write entry points |
| bot_repo_sqlite.odin:399 | `bot_insert_sqlite` | direct gate |
| bot_repo_sqlite.odin:461 | `bot_set_instance_sqlite` | direct gate |
| bot_repo_sqlite.odin:480 | `bot_delete_sqlite` | direct gate |
| bot_repo_sqlite.odin:541 | `binding_revoke_sqlite` | direct gate |
| bot_repo_sqlite.odin:555 | `pairing_insert_sqlite` | direct gate |
| bot_repo_sqlite.odin:582 | `pairing_delete_for_owner_sqlite` | direct gate |
| bot_repo_sqlite.odin:596 | `message_insert_outbound_sqlite` | direct gate |
| bot_repo_sqlite.odin:640 | `message_set_send_result_sqlite` | direct gate |
| bot_repo_sqlite.odin:692 | `messages_mark_replied_sqlite` | direct gate |
| bot_repo_sqlite.odin:711 | `messages_purge_binding_sqlite` | direct gate |
| bot_repo_sqlite.odin:733 | `messages_purge_older_than_sqlite` | direct gate |
| bot_repo_sqlite.odin:780 | `delivery_insert_sqlite` | direct gate |
| bot_repo_sqlite.odin:832 | `attempt_insert_sqlite` | direct gate |
| bot_repo_sqlite.odin:921 | `delivery_update_sqlite` | direct gate |
| bot_repo_sqlite.odin:955 | `attempt_update_sqlite` | direct gate |
| bot_repo_sqlite.odin:1026 | `placement_replace_sqlite` | direct gate |
| bot_repo_sqlite.odin:1075 | `binding_activate_sqlite` | direct gate |
| bot_repo_sqlite.odin:1139 | `inbound_store_batch_sqlite` | direct gate |
| bot_repo_sqlite.odin:1209 | `messages_mark_read_sqlite` | direct gate |
| bot_repo_sqlite.odin:1239 | `pairing_consume_sqlite` | direct gate |
| bot_repo_sqlite.odin:1296 | `binding_set_reengage_sqlite` | direct gate |
| bot_repo_sqlite.odin:1311 | `push_events_insert_sqlite` | direct gate |
| bot_repo_sqlite.odin:1408 | `push_batch_commit_sqlite` | direct gate |
| bot_repo_sqlite.odin:1483 | `push_events_purge_processed_sqlite` | direct gate |
| bot_repo_sqlite.odin:1494 | `messages_mark_replied_binding_sqlite` | direct gate |
| bot_repo_sqlite.odin:1539 | `bot_repo_insert_attachment` | helper called by gated inbound_store_batch_sqlite / web_message_store_sqlite |
| bot_repo_sqlite.odin:1617 | `attachment_store_artifact_sqlite` | direct gate |
| bot_repo_sqlite.odin:1645 | `attachment_set_state_sqlite` | direct gate |
| bot_web_sqlite.odin:9 | `web_message_store_sqlite` | direct gate before db_mutex and BEGIN |
| bridge_log_repo_sqlite.odin:46 | `bridge_log_insert_batch_sqlite` | direct gate |
| bridge_log_repo_sqlite.odin:87 | `bridge_log_cap_bridge_sqlite` | direct gate |
| bridge_log_repo_sqlite.odin:108 | `bridge_log_prune_before_sqlite` | direct gate |
| bridge_log_repo_sqlite.odin:154 | `bridge_log_delete_by_bridge_sqlite` | direct gate |
| bridge_plan_repo_sqlite.odin:10 | `bridge_create_limited_sqlite` | direct gate |
| bridge_plan_repo_sqlite.odin:29 | `bridge_create_limited_on` | internal helper under gated bridge-plan entry points, gate precedes dedicated BEGIN |
| bridge_plan_repo_sqlite.odin:62 | `sunset_exec` | SQL helper under gated bridge-plan entry points |
| bridge_plan_repo_sqlite.odin:79 | `bridge_sunset_on` | internal helper under gated bridge-plan entry points, gate precedes dedicated BEGIN |
| bridge_plan_repo_sqlite.odin:111 | `bridge_drop_sunset_receipt` | internal helper under gated bridge-plan entry points, gate precedes dedicated BEGIN |
| bridge_plan_repo_sqlite.odin:117 | `bridge_delete_pending_restoring_sunset_sqlite` | direct gate |
| bridge_plan_repo_sqlite.odin:132 | `bridge_delete_pending_restoring_sunset_on` | internal helper under gated bridge-plan entry points, gate precedes dedicated BEGIN |
| bridge_plan_repo_sqlite.odin:241 | `bridge_reconcile_plan_sqlite` | direct gate |
| bridge_plan_repo_sqlite.odin:253 | `bridge_reconcile_plan_on` | internal helper under gated bridge-plan entry points, gate precedes dedicated BEGIN |
| bridge_repo_sqlite.odin:78 | `bridge_save_bridge_sqlite` | direct gate |
| bridge_repo_sqlite.odin:95 | `bridge_update_runtime_sqlite` | direct gate |
| bridge_repo_sqlite.odin:183 | `bridge_delete_pending_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:24 | `bridge_save_token_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:124 | `bridge_revoke_token_family_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:138 | `bridge_revoke_family_with_receipts_on` | internal helper under gated bridge-token/plan entry points |
| bridge_token_repo_sqlite.odin:152 | `bridge_revoke_token_family_on` | internal helper under gated bridge-token/plan entry points |
| bridge_token_repo_sqlite.odin:169 | `bridge_revoke_token_family_in_scope_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:191 | `bridge_revoke_tokens_for_bridge_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:207 | `bridge_revoke_with_receipts_on` | internal helper under gated bridge-token/plan entry points |
| bridge_token_repo_sqlite.odin:224 | `bridge_revoke_tokens_for_bridge_on` | internal helper under gated bridge-token/plan entry points |
| bridge_token_repo_sqlite.odin:239 | `bridge_mark_token_used_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:268 | `bridge_regrant_atomic_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:286 | `bridge_regrant_on` | internal helper under gated bridge-token/plan entry points |
| bridge_token_repo_sqlite.odin:329 | `bridge_insert_token_on` | internal helper under gated bridge-token/plan entry points |
| bridge_token_repo_sqlite.odin:361 | `bridge_mark_token_rotated_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:395 | `bridge_commit_enrollment_sqlite` | direct gate |
| bridge_token_repo_sqlite.odin:420 | `bridge_commit_enrollment_on` | internal helper under gated bridge-token/plan entry points |
| card_repo_sqlite.odin:106 | `card_create_sqlite` | direct gate |
| card_repo_sqlite.odin:191 | `card_update_status_sqlite` | direct gate |
| card_repo_sqlite.odin:216 | `card_update_sqlite` | direct gate |
| card_repo_sqlite.odin:272 | `card_delete_sqlite` | direct gate |
| conn.odin:132 | `exec` | low-level SQL primitive: startup, owner UoW, or gated repository caller; not a domain mutation entry point |
| conn.odin:160 | `step_changes` | low-level statement primitive; gated domain caller owns transaction gate |
| content_repo_sqlite.odin:19 | `content_save_memory_sqlite` | direct gate |
| content_repo_sqlite.odin:37 | `content_save_conversation_sqlite` | direct gate |
| content_repo_sqlite.odin:96 | `content_save_message_sqlite` | direct gate |
| content_repo_sqlite.odin:101 | `content_update_message_sqlite` | direct gate |
| content_repo_sqlite.odin:198 | `content_mark_messages_read_sqlite` | direct gate |
| content_repo_sqlite.odin:227 | `content_save_artifact_sqlite` | direct gate |
| content_repo_sqlite.odin:359 | `content_delete_artifact_sqlite` | direct gate |
| content_repo_sqlite.odin:364 | `content_save_template_sqlite` | direct gate |
| content_repo_sqlite.odin:370 | `content_delete_template_sqlite` | direct gate |
| conversation_launch_preferences.odin:16 | `launch_preferences_save_sqlite` | direct gate |
| event_outbox_repo.odin:37 | `outbox_append` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_outbox_repo.odin:74 | `outbox_mark` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_outbox_repo.odin:92 | `outbox_prune` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_outbox_repo.odin:102 | `outbox_next_version` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_outbox_repo.odin:113 | `outbox_open_topic` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_outbox_repo.odin:137 | `outbox_resolve_topic` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:53 | `subscription_put` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:116 | `subscription_remove` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:129 | `subscription_delivered` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:250 | `subscription_queue_delete` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:261 | `subscription_prune` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:281 | `subscription_trim_receipts` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:292 | `subscription_mark_delivery` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| event_subscription_repo.odin:342 | `subscription_deleted` | UoW required by subscription_prepare/outbox_prepare (outbox_uow_owns) |
| experiment_repo_sqlite.odin:24 | `experiment_set_sqlite` | direct gate |
| external_identity.odin:40 | `user_resolve_external_sqlite` | direct gate |
| external_identity.odin:125 | `user_link_external_sqlite` | direct gate |
| external_identity.odin:162 | `user_unlink_external_sqlite` | direct gate |
| external_identity.odin:178 | `user_set_status_sqlite` | direct gate |
| fts_repair.odin:54 | `repair_fts_indexes` | direct gate (before repository/db mutex) |
| fts_repair.odin:104 | `fts_rebuild_one` | internal helper of gated repair_fts_indexes |
| fts_repair.odin:135 | `step_write_healing` | direct gate (before repository/db mutex) |
| instance_reconfiguration_repo.odin:27 | `instance_reconfiguration_begin_sqlite` | write_sqlite opens UoW before dispatching begin/advance impl; wrappers cannot bypass |
| instance_reconfiguration_repo.odin:31 | `instance_reconfiguration_advance_sqlite` | write_sqlite opens UoW before dispatching begin/advance impl; wrappers cannot bypass |
| instance_reconfiguration_repo.odin:38 | `instance_reconfiguration_write_sqlite` | write_sqlite opens UoW before dispatching begin/advance impl; wrappers cannot bypass |
| instance_reconfiguration_repo.odin:55 | `instance_reconfiguration_begin_impl` | write_sqlite opens UoW before dispatching begin/advance impl; wrappers cannot bypass |
| instance_reconfiguration_repo.odin:87 | `instance_reconfiguration_advance_impl` | write_sqlite opens UoW before dispatching begin/advance impl; wrappers cannot bypass |
| issue_repo_sqlite.odin:62 | `issue_save_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| issue_repo_sqlite.odin:219 | `issue_update_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| issue_repo_sqlite.odin:257 | `issue_delete_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| issue_repo_sqlite.odin:295 | `issue_comment_save_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| issue_repo_sqlite.odin:351 | `issue_comment_delete_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| issue_repo_sqlite.odin:386 | `issue_vote_save_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| issue_repo_sqlite.odin:419 | `issue_vote_remove_sqlite` | direct gate; issue service mutations have no UoW/state lock |
| lsp_server_config_repo_sqlite.odin:41 | `lsp_server_config_upsert_sqlite` | direct gate; REST upsert/delete callers run outside UoW |
| lsp_server_config_repo_sqlite.odin:120 | `lsp_server_config_delete_sqlite` | direct gate; REST upsert/delete callers run outside UoW |
| mcp_mutations.odin:31 | `mcp_receipt_put` | direct gate (before repository/db mutex) |
| mcp_mutations.odin:55 | `mcp_runtime_receipt_update` | direct gate (before repository/db mutex) |
| mcp_repo_sqlite.odin:30 | `mcp_cleanup` | dedicated MCP_Repo_SQLite.conn opened by open_mcp_repository; not the native shared transaction view |
| mcp_repo_sqlite.odin:58 | `mcp_transaction_sqlite` | direct gate before dedicated MCP mutex/BEGIN; callbacks may use gated native write helpers |
| mcp_repo_sqlite.odin:92 | `mcp_put_sqlite` | direct gate (before repository/db mutex) |
| mcp_repo_sqlite.odin:106 | `mcp_remove_sqlite` | direct gate (before repository/db mutex) |
| migrations.odin:1008 | `run_migrations` | startup-only: app/wiring.odin runs migrations before repository/service setup; helpers only called by run_migrations |
| migrations.odin:1893 | `mark_migration_applied` | startup-only: app/wiring.odin runs migrations before repository/service setup; helpers only called by run_migrations |
| migrations.odin:1901 | `upgrade_user_api_tokens_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:1915 | `upgrade_task_comments_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:1995 | `upgrade_task_chains_v2_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2001 | `upgrade_memory_target_scope_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2017 | `upgrade_memory_scope_lists_schema` | startup-only: app/wiring.odin runs migrations before repository/service setup; helpers only called by run_migrations |
| migrations.odin:2031 | `upgrade_chat_message_types_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2038 | `upgrade_current_task_and_priority_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2045 | `upgrade_title_tracking_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2056 | `upgrade_agent_instance_display_name_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2064 | `upgrade_push_subscriptions_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2082 | `upgrade_memory_description_schema` | startup-only: app/wiring.odin runs migrations before repository/service setup; helpers only called by run_migrations |
| migrations.odin:2095 | `upgrade_cards_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2127 | `upgrade_projects_state_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2134 | `upgrade_artifact_indexes_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2148 | `upgrade_pinned_task_chains_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2157 | `upgrade_task_chain_directories_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2180 | `upgrade_task_chain_fleets_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2210 | `upgrade_task_bridge_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2225 | `upgrade_task_v2_schema` | startup-only: app/wiring.odin runs migrations before repository/service setup; helpers only called by run_migrations |
| migrations.odin:2271 | `drop_legacy_column` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2281 | `upgrade_vault_directory_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2302 | `upgrade_shell_sessions_kind_and_key_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2317 | `upgrade_shell_sessions_background_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2340 | `upgrade_shell_sessions_run_seq_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2357 | `upgrade_shell_sessions_kill_intent_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2371 | `upgrade_bridge_version_and_updates_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2381 | `upgrade_bridge_update_progress_schema` | startup-only helper of run_migrations (before request threads) |
| migrations.odin:2388 | `upgrade_memory_action_expiry_schema` | startup-only helper of run_migrations (before request threads) |
| mixed_work_repo_sqlite.odin:25 | `insert_work_dependency_sqlite` | direct gate |
| mixed_work_repo_sqlite.odin:83 | `insert_work_input_receipt_sqlite` | direct gate |
| mixed_work_repo_sqlite.odin:159 | `append_work_scope_decision_sqlite` | direct gate |
| mixed_work_repo_sqlite.odin:199 | `remove_work_dependency_sqlite` | direct gate |
| mixed_work_repo_sqlite.odin:228 | `complete_work_chain_sqlite` | direct gate |
| multi_question.odin:9 | `content_answer_question_sqlite` | direct gate |
| pipeline_delivery_repo_sqlite.odin:88 | `pipeline_insert` | UoW required by pipeline_prepare |
| pipeline_delivery_repo_sqlite.odin:111 | `pipeline_transition` | UoW required by pipeline_prepare |
| pipeline_delivery_repo_sqlite.odin:207 | `pipeline_prune` | UoW required by pipeline_prepare |
| project_repo_sqlite.odin:42 | `project_save_sqlite` | direct gate |
| project_repo_sqlite.odin:57 | `project_save_bridge_path_sqlite` | direct gate |
| project_repo_sqlite.odin:86 | `project_delete_bridge_path_sqlite` | direct gate |
| provider_extension_commands.odin:4 | `provider_extension_command_create_sqlite` | direct gate |
| provider_extension_commands.odin:45 | `provider_extension_command_save_sqlite` | direct gate |
| provider_profiles.odin:87 | `bridge_provider_profiles_reconcile_sqlite` | direct gate |
| provider_repo_sqlite.odin:35 | `bridge_provider_status_upsert_sqlite` | direct gate |
| provider_repo_sqlite.odin:65 | `bridge_provider_setting_upsert_sqlite` | direct gate |
| provider_repo_sqlite.odin:220 | `bridge_provider_models_upsert_sqlite` | direct gate |
| provider_repo_sqlite.odin:271 | `set_provider_transport_sqlite` | direct gate |
| push_repo_sqlite.odin:39 | `push_upsert_by_endpoint_sqlite` | direct gate |
| push_repo_sqlite.odin:120 | `push_delete_by_endpoint_sqlite` | direct gate |
| push_repo_sqlite.odin:145 | `push_delete_by_id_sqlite` | direct gate |
| session_repo_sqlite.odin:57 | `session_create_sqlite` | direct gate |
| session_repo_sqlite.odin:84 | `session_touch_sqlite` | direct gate |
| session_repo_sqlite.odin:96 | `session_delete_sqlite` | direct gate |
| session_repo_sqlite.odin:116 | `session_purge_expired_sqlite` | direct gate |
| session_repo_sqlite.odin:138 | `session_delete_user_sqlite` | delegates to gated delete_user_sessions_sqlite |
| session_repo_sqlite.odin:145 | `delete_user_sessions_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:88 | `shell_session_upsert_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:559 | `shell_session_set_server_port_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:583 | `shell_session_delete_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:624 | `shell_session_delete_terminal_before_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:638 | `shell_session_delete_terminal_before_owners_sqlite` | direct gate |
| shell_session_repo_sqlite.odin:846 | `shell_session_set_kill_requested_sqlite` | direct gate |
| sqlite_metrics.odin:78 | `sqlite3_step` | instrumented SQLite ABI primitive; gate belongs to domain/UoW entry point |
| sqlite_metrics.odin:86 | `sqlite3_exec` | instrumented SQLite ABI primitive; gate belongs to domain/UoW entry point |
| taskchain_repo_sqlite.odin:163 | `taskchain_save_chain_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:177 | `task_save_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:222 | `task_comment_save_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:344 | `taskchain_save_member_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:358 | `taskchain_remove_member_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:399 | `taskchain_save_dependency_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:413 | `taskchain_remove_dependency_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:439 | `taskchain_save_directory_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:487 | `taskchain_remove_directory_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:529 | `taskchain_upsert_fleet_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:555 | `taskchain_ensure_fleet_sqlite` | direct gate |
| taskchain_repo_sqlite.odin:595 | `taskchain_delete_fleet_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:61 | `taskchain_take_boot_regate_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:92 | `task_event_append_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:181 | `task_attempt_save_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:224 | `task_attempt_facet_save_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:279 | `task_lease_save_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:343 | `task_lease_delete_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:376 | `task_review_save_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:424 | `chain_summary_save_sqlite` | direct gate |
| taskv2_repo_sqlite.odin:454 | `workflow_definition_save_sqlite` | direct gate |
| user_repo_sqlite.odin:38 | `user_save_sqlite` | direct gate |
| vault_directory_repo_sqlite.odin:72 | `vault_consume_request_nonce_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:202 | `insert_device_on` | internal helper under gated vault entry points |
| vault_directory_repo_sqlite.odin:301 | `insert_log_on` | internal helper under gated vault entry points |
| vault_directory_repo_sqlite.odin:316 | `vault_mark_retired_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:391 | `vault_register_pending_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:474 | `vault_delete_pending_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:496 | `vault_touch_last_seen_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:524 | `insert_epoch_on` | internal helper under gated vault entry points |
| vault_directory_repo_sqlite.odin:537 | `upsert_wrap_on` | internal helper under gated vault entry points |
| vault_directory_repo_sqlite.odin:550 | `vault_create_genesis_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:611 | `vault_commit_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:758 | `vault_schedule_reset_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:793 | `vault_cancel_reset_sqlite` | direct gate (before repository/db mutex) |
| vault_directory_repo_sqlite.odin:835 | `vault_execute_reset_sqlite` | direct gate (before repository/db mutex) |
| workflow_run_repo_sqlite.odin:29 | `insert_workflow_run_sqlite` | direct gate |
| workflow_run_repo_sqlite.odin:56 | `update_workflow_run_sqlite` | direct gate |
| workflow_run_repo_sqlite.odin:148 | `insert_workflow_execution_sqlite` | direct gate |
| workflow_run_repo_sqlite.odin:172 | `update_workflow_execution_sqlite` | direct gate |
| workflow_run_repo_sqlite.odin:243 | `insert_workflow_stage_execution_sqlite` | direct gate |
| workflow_run_repo_sqlite.odin:296 | `append_workflow_run_event_sqlite` | direct gate |

## Reviewed caller evidence

- LSP configuration REST create/update/delete handlers call the repository directly without a UoW; both mutation entry points now enter the gate.
- Issue service create/update/delete/comment/vote methods similarly call mutation interfaces without state locks or a UoW; all seven mutation entry points now enter the gate.
- Every outbox/subscription statement is prepared through `outbox_prepare`/`subscription_prepare`; both reject unless `outbox_uow_owns` verifies positive transaction depth, the current owner thread, and exact connection identity. This protects their decision reads too.
- The sole production `run_migrations` call is in `app/wiring.odin` before repositories/services are wired. Listed migration helpers are only called by that startup procedure. They are not request-time writes.

Decision-read gate: `issue_get_sqlite` feeds issue service update/comment/vote existence and state checks (`issue_service.odin` update_issue, add_comment, add_vote). It now waits for another thread UoW to settle rather than allowing an action based on a rolled-back issue. Issue listing/count/display-only reads remain unchanged.

Decision-read evidence: `agent_get_instance_sqlite` supplies agent-service start eligibility and owner checks; `bridge_get_by_column` supplies token verification, revoked/plan admission and runtime mutation snapshots; `bridge_get_token_sqlite` and `bridge_list_tokens_by_family_sqlite` supply access/refresh verification and newest-generation/reuse decisions in `bridge_token_service.odin`. Each now enters the gate before reading, and UoW-owned reads reuse their owner gate. Display/list-only reads remain unchanged.

## Coverage and limits

The table contains 262 entries, including internal/startup/SQL-helper candidates. Runtime rollback tests cover both changed Agent and Bridge repositories; representative rollback tests cover every other changed repository interface in `tx_repository_rollback_test.odin`. Dedicated billing mutations are exempt because their constructor opens a distinct handle, not because callers happen to hold a UoW. Vault mutations also gate the in-memory shared-handle fallback. Native MCP shared-handle writes gate individually; its legacy dedicated transaction enters the gate before BEGIN to avoid an inversion with those helpers. Display-only reads are not blanket-gated.

Cross-check: every table symbol and line resolves; every direct-gate entry contains its guard. A conservative DML/DDL scan has no unlisted procedure candidates after four manually reviewed constant boundaries (`actions_rule_query`, `actions_run_joined_count`, `new_pipeline_delivery_repository`, `vault_list_due_resets_sqlite`), where SQL constants follow a read/constructor and belong to the next consuming writer.

## Service and transport mutex order audit

Repository-local order alone is insufficient: a newly gated operation adds
`M -> tx_mutex` whenever its caller holds another mutex M. The reverse path
must either be absent from the current production call graph, release M before
repository work, or take the transaction first. Paths in this section are
relative to `src/hub`. The sweep enumerated lock sites in `service`,
`transport/http` and `app`, inspected their scope (including helper calls), and
checked callbacks from UoW-owned taskchain/card/native-MCP paths. A lock and a
repository call appearing in the same procedure is not itself an overlap.

| Mutex / caller | Gated overlap and ordering evidence |
| --- | --- |
| `Card_Service.projector_mutex` | **Fixed:** `service/card/card_projector.odin:project_attention_in_uow` begins the Card_Service UoW before taking this mutex for every task/message/memory entry point, including placement projection. A taskchain/content caller already owning a UoW nests without reacquiring the gate; reconciliation starts its own outer UoW first. Unlock precedes commit. Card-change hooks are heap-owned after-commit effects; rollback discards them. Production wiring always supplies the factory; nil supports isolated legacy repository doubles. The bounded two-thread regression exercises a taskchain comment verb under A UoW while B reconciles, detects the old order without hanging, and verifies notifications happen outside both locks. |
| `Card_Service.mark_card_accepted` | The CAS in `card_service.odin:mark_card_accepted` (formerly line 1290) takes **no projector mutex**. `accept_card` commits its own operation UoW before calling it; a possible caller-owned outer UoW can reuse the repository gate without introducing a projector edge. |
| `experiment_set_mutex` | `transport/http/experiment_rest_handlers.odin:experiment_set_handler` holds it over `experiment_set` and the experiment-change hook. Its only acquisition is this HTTP verb; no UoW-owned service/projector path calls this handler or takes this mutex. The experiment-change callback may take bot service locks, but a transaction owner never calls back into the HTTP setter. |
| `Provider_Service.extension_mutex` | Acquired only by extension transport start/reconnect/frame handlers in `provider_extension_handlers.odin`. They serialize command create/save and profile reconciliation. UoW-owned provider/agent operations use repository/profile selection interfaces and never call these transport handlers or acquire extension_mutex. Command dispatch is asynchronous; there is no synchronous WS-reader command wait under it. |
| `User_Service.launch_preferences_mutex` | `user_service.odin:ensure_canonical_resources` and `conversation_launch_preferences.odin:set_launch_selection/set_agent_favorite_locked`, plus `agent_handlers.odin:create_agent_handler`, hold it over agent/project/preferences writes. Acquisitions belong to canonical-user provisioning and launch-selection/agent-create HTTP entry paths. UoW-owned card/task/native mutation paths use agent/project repositories/services directly, not these launch-selection handlers or canonical-resource provisioning; there is no transaction-owned acquisition. |
| `agent_start_success_mutex` | Only `agent_action_start_success_handler` acquires it, before instance authentication and ready-note/generation writes. It may call startup-message and reconfiguration routines. UoW paths record/confirm generations through service/repository methods, never by entering this HTTP start-success handler; therefore no `tx -> agent_start_success_mutex` edge. |
| `startup_message_mutex` | Only `content/startup_message.odin:send_agent_startup_message` acquires it over the ready-note existence/write path. Called by the start-success HTTP flow. Task/native/card UoW operations may write messages and notify projectors, but do not create startup notes or acquire this mutex. |
| `previous_context_mutex` | Only `content/previous_context.odin:store_previous_context` takes it over previous-context message/conversation writes. The instance previous-context HTTP action invokes it; generic content saves and projectors do not call back into it. No UoW-owned acquisition path exists. |
| `Agent_Service.reconfiguration_mutex` | Stop/reconfigure/start-begin/retry/reconcile entry points serialize gated instance writes and repository-owned reconfiguration UoWs. The task-engine transaction path uses `agent/start_begin.odin:prepare_start_in_uow`, explicitly mutex- and network-free; its generation ticket is dispatched only after commit. Native MCP runtime actions release their authorization UoW before invoking guarded runtime methods. Card archive changes the agent row; it does not stop instances or take this mutex. No task/card UoW path takes reconfiguration_mutex. |
| `Bots_Service.mutex` | Bot pairing/delivery/report/supervisor/web-send methods hold it over gated bot/agent writes and may begin their own UoWs. External callers are bot HTTP verbs, provider/push/supervisor loops and bridge frame hooks. `bridge_handlers.odin` calls `bots_on_bridge_hello/disconnect` after admission/disconnect persistence commits. Task engine does not call bot service methods while owning its UoW; delivery work is dispatched after commit. No `tx -> Bots_Service.mutex` path exists. |
| `Bots_Runtime.lifecycle_mutex` | `bots/runtime.odin:bots_runtime_reconcile/stop` manages provider-worker lifecycle; called by app/reaper/experiment-change paths, never from a UoW-owned business operation. Count/cache reads do not enter the shared write gate; worker callbacks run on their own threads. No transaction-owned lifecycle acquisition. |
| `Bots_Service.reengage_mutex` | Confirmed separately: its sole acquisition is `bots/window.odin:bots_reengage`, which reads a binding, calls the provider and persists `binding_set_reengage`. Callers are `channel_send`, `channel_send_media` and `bots_on_delivery_failed`. `channel_send/media` are reached by bot-agent HTTP send handlers and pairing replies; delivery-failed comes from the push/provider loop. These paths are outside a UoW (they perform provider I/O); send-state repository guards have returned before re-engagement. Task/native/card UoW code never calls channel send, media send, delivery-failed or re-engagement. This is `reengage -> tx` only, with no reverse edge; moving provider delivery into a UoW would violate this invariant and the existing no-network-in-UoW rule. |
| `Billing_Service.entitlements_mutex` | `billing/entitlements.odin` holds it during cache fills. Fill reads use the independently opened query-only billing connection and have no write side effects or shared repository gate acquisition. Startup/webhook/reaper bridge-plan reconciliation is outside the cache-fill section. `tx -> entitlements_mutex` is allowed because `entitlements_mutex -> tx` is absent. |
| `Bridge_Runtime_Connection.state_mutex` | Runtime hello/status/disconnect/vault/heartbeat/features now snapshot under it inside a UoW opened first, unlock, then perform DB operations. No DB read/write under state_mutex takes a new gate; generation metadata updates alone remain under the state lock. Registry metadata/command/writer/chunk/retire locks cover memory/socket state only. |
| Agent blocker/tool-stream/bootstrap cache mutexes | `agent_blockers.odin:apply_bridge_blockers_snapshot` performs the gated `agent_get_instance` before blockers.mutex. Blocker resolution and tool stream locks manipulate memory/socket routes, not gated repository writes. `bootstrap_manifest_conditional` cache lookup/insert does not overlap a newly gated write (its agent-definition read is not a newly gated decision read). No overlapping write-gate edge. |
| Shell session `mu`, `tunnel_mu`, pane/snapshot/writer locks | Session create unlocks its tracking-map mutex before the upserts/bridge spawn result writes; `shell_session_handle_exited` unlocks at its map-removal section before the terminal upsert. Other restarts/upserts likewise run outside these map/viewer locks. Tunnel/pane locks guard socket buffers and routing, not repository mutation. The same-function lock/SQL matches are separated scopes, not `mu -> tx`. |
| Bridge log `Service.mu` | `bridge_log_service.odin:flush_once` detaches the queue then unlocks before insert/cap; `purge_bridge` removes queued entries then unlocks before the gated delete. No gate is acquired while its queue mutex is held. |
| Delivery service/forwarder lifecycle and answer mutexes | `delivery/offline.odin:on_bridge_online` reads the gated bridge and finishes `bridge_rows` UoW before service/forwarder lifecycle locks. Pipeline transitions have explicit owner UoWs; queue/lifecycle sections do not call newly gated writes. |
| Taskv2 state/timer/merge/coordinator-wake guards | Pending touch/state/timer locks snapshot queue data and release before transactional writes/flush. Engine attention/launch effects are emitted after commit. Merge/coordinator delivery guards manage post-commit work and are not acquired by gated repository writers. No new opposite acquisition path is introduced. |
| Auth/device-grant/vault nonce caches; provider model caches; event bus/debouncer/poll-hint locks | These locks guard in-memory maps, cached keys, viewer buffers or counters; repository calls happen before/after those sections. SQL-backed session/identity/directory writes are not performed under these cache locks. Event hooks can be called by business UoWs but the memory locks never enter a repository gate. |
| HTTP preview/relay stream locks and app MCP runtime guard | Proxy stream locks serialize socket buffers/commands, not SQL mutation. Native MCP runtime serialization uses a nonblocking try-lock; its authorization UoWs finish before stop/reconfigure/network runtime calls, so it does not introduce a blocking transaction-to-runtime-lock cycle. |

This audit describes the current call graph, not permission to acquire an
arbitrary service mutex while holding a UoW. In particular, new callbacks into
HTTP setters, channel-provider I/O, startup-note creation or reconfiguration
must preserve the directions above. Repository guards remain in place; the
projector fix removes the identified reverse edge rather than weakening them.
