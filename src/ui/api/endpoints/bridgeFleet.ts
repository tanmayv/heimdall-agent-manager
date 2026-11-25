import { cookieJsonFetch, cookieMutation, customQueryError } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';

/** Mirrors src/contracts/fleet_settings.odin. Runtime profiles are stable IDs. */
export interface FleetRuntime { provider: string; provider_profile: string; model: string }
export interface FleetAgentOverride { agent_id: string; runtime: FleetRuntime }
export interface FleetSettings { bridge_id: string; revision: number; default_runtime: FleetRuntime; overrides: FleetAgentOverride[] }
export interface FleetApplyInput { request_id: string; expected_revision: number; default_runtime: FleetRuntime; overrides: FleetAgentOverride[] }
export interface FleetPreview { bridge_id: string; expected_revision: number; affected_instances: number }
export interface FleetApplicationTarget {
  agent_instance_id: string; agent_id: string; configuration_revision: number; run_count: number;
  launch_epoch: string; project_id: string; lease_id: string; before: FleetRuntime; desired: FleetRuntime;
  operation_key: string; state: 'pending' | 'restarting' | 'ready' | 'failed';
  error_code: string; error_message: string; retryable: boolean;
}
export interface FleetApplication {
  application_id: string; bridge_id: string; request_id: string; settings_revision: number; revision: number;
  settings_saved: boolean; cancelled: boolean; state: 'pending' | 'restarting' | 'ready' | 'partial_failure';
  created_at: string; updated_at: string; targets: FleetApplicationTarget[];
}
const path = (bridgeId: string) => `/bridges/${encodeURIComponent(bridgeId)}/fleet`;
const changed = (bridgeId: string) => [
  { type: 'BridgeFleetSettings' as const, id: bridgeId },
  { type: 'TaskChainFleets' as const }, { type: 'AgentInstances' as const, id: 'LIST' },
];
export const bridgeFleetApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getBridgeFleetSettings: build.query<FleetSettings, string>({
      queryFn: async (bridgeId) => {
        try { return { data: await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/launch-defaults`) }; }
        catch (error) { return { error: customQueryError(error) as any }; }
      },
      providesTags: (_r, _e, bridgeId) => [{ type: 'BridgeFleetSettings', id: bridgeId }],
    }),
    applyBridgeFleet: build.mutation<FleetApplication, { bridgeId: string; input: FleetApplyInput }>({
      queryFn: async ({ bridgeId, input }) => {
        try { return { data: await cookieMutation(`${path(bridgeId)}/apply`, 'POST', input) }; }
        catch (error) { return { error: customQueryError(error) as any }; }
      },
      invalidatesTags: (result, _e, { bridgeId }) => result ? changed(bridgeId) : [],
    }),
    previewBridgeFleet: build.query<FleetPreview, { bridgeId: string; draft: Omit<FleetApplyInput, 'request_id'> }>({
      queryFn: async ({ bridgeId, draft }) => {
        try { return { data: await cookieMutation(`${path(bridgeId)}/preview`, 'POST', draft) }; }
        catch (error) { return { error: customQueryError(error) as any }; }
      },
      // Previews are draft-specific. Instance startup never invalidates this read.
      keepUnusedDataFor: 0,
    }),
    getBridgeFleetApplication: build.query<FleetApplication, { bridgeId: string; applicationId: string }>({
      queryFn: async ({ bridgeId, applicationId }) => {
        try { return { data: await cookieJsonFetch(`${path(bridgeId)}/applications/${encodeURIComponent(applicationId)}`) }; }
        catch (error) { return { error: customQueryError(error) as any }; }
      },
      providesTags: (_r, _e, { applicationId }) => [{ type: 'BridgeFleetApplication', id: applicationId }],
    }),
    retryBridgeFleetApplication: build.mutation<FleetApplication, { bridgeId: string; applicationId: string }>({
      queryFn: async ({ bridgeId, applicationId }) => {
        try { return { data: await cookieMutation(`${path(bridgeId)}/applications/${encodeURIComponent(applicationId)}/retry`, 'POST') }; }
        catch (error) { return { error: customQueryError(error) as any }; }
      },
      invalidatesTags: (result, _e, { bridgeId, applicationId }) => result
        ? [...changed(bridgeId), { type: 'BridgeFleetApplication' as const, id: applicationId }] : [],
    }),
  }),
});
export const { useGetBridgeFleetSettingsQuery, useApplyBridgeFleetMutation, usePreviewBridgeFleetQuery, useGetBridgeFleetApplicationQuery, useRetryBridgeFleetApplicationMutation } = bridgeFleetApi;
