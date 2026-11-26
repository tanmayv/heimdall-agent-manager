// Mirrors src/contracts/fleet_settings.odin. F2 exposes these through Apply.
export interface FleetRuntime {
  provider: string
  provider_profile: string
  model: string
}
export interface FleetAgentOverride {
  agent_id: string
  runtime: FleetRuntime
}
export interface FleetSettings {
  bridge_id: string
  revision: number
  default_runtime: FleetRuntime
  overrides: FleetAgentOverride[]
}
export interface FleetSettingsDraft {
  expected_revision: number
  default_runtime: FleetRuntime
  overrides: FleetAgentOverride[]
}

export interface FleetApplyInput extends FleetSettingsDraft { request_id: string }
export interface FleetApplicationTarget {
  agent_instance_id: string
  agent_id: string
  configuration_revision: number
  run_count: number
  launch_epoch: string
  project_id: string
  lease_id: string
  before: FleetRuntime
  desired: FleetRuntime
  operation_key: string
  state: 'pending' | 'restarting' | 'ready' | 'failed'
  error_code: string
  error_message: string
  retryable: boolean
}
export interface FleetApplication {
  application_id: string
  bridge_id: string
  request_id: string
  settings_revision: number
  revision: number
  settings_saved: boolean
  cancelled: boolean
  state: 'pending' | 'restarting' | 'ready' | 'partial_failure'
  created_at: string
  updated_at: string
  targets: FleetApplicationTarget[]
}
