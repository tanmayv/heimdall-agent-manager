import { heimdallApi } from '../heimdallApi';
import {
  activityFixture, uptimeFixture, fleetFixture, chainsFixture, chainDetailFixture,
} from '../../components/home/homeWidgetFixtures';
import { activityFromWire, uptimeFromWire, fleetFromWire, type ActivityData, type ActivityMetric, type FleetBridge, type UptimeData, type HomeChainPage, type HomeChainDetail } from '../../components/home/widgetData';

/**
 * UI-first endpoint seams. Fixtures use the documented HTTP response shapes.
 * T4 replaces queryFn's fixture call with cookieJsonFetch at the named route;
 * the hooks and response adapters remain the same.
 */
export const homeApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getHomeActivity: build.query<ActivityData, ActivityMetric>({
      // GET /me/activity?metric=&days=371&tz=
      queryFn: async (metric) => ({ data: activityFromWire(activityFixture(metric)) }),
    }),
    getHomeUptime: build.query<UptimeData, void>({
      // GET /me/uptime?days=30&tz=
      queryFn: async () => ({ data: uptimeFromWire(uptimeFixture()) }),
    }),
    getHomeTaskChains: build.query<HomeChainPage, { page: number }>({
      // GET /task-chains?status=active&limit=3&cursor=
      queryFn: async ({ page }) => ({ data: chainsFixture(page) }),
    }),
    getHomeChainDetail: build.query<HomeChainDetail, string>({
      // GET /task-chains/{id}
      queryFn: async (id) => {
        const detail = chainDetailFixture(id);
        const bridges = fleetFixture().bridges;
        return { data: { ...detail, members: detail.members.map((member) => ({ ...member, bridge_label: bridges.find((bridge) => bridge.bridge_id === member.bridge_id)?.label })) } };
      },
    }),
    getHomeFleet: build.query<FleetBridge[], void>({
      // Compose GET /bridges with each bridge's /launch-defaults and
      // /agent-overrides; no aggregate HTTP endpoint is introduced.
      queryFn: async () => ({ data: fleetFromWire(fleetFixture()) }),
    }),
  }),
});
export const {
  useGetHomeActivityQuery, useGetHomeUptimeQuery, useGetHomeTaskChainsQuery,
  useGetHomeChainDetailQuery, useGetHomeFleetQuery,
} = homeApi;
