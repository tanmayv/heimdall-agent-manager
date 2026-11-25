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
