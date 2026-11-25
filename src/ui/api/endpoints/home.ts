import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, customQueryError } from '../cookieFetch';
import { bridgeIdOf, bridgeIsOnline, bridgeLabel } from '../../utils/bridgeLaunchOptions';
import {
  activityFixture, uptimeFixture, fleetFixture, chainsFixture, chainDetailFixture,
} from '../../components/home/homeWidgetFixtures';
import { activityFromWire, uptimeFromWire, type ActivityData, type ActivityMetric, type FleetBridge, type UptimeData, type HomeChainPage, type HomeChainDetail } from '../../components/home/widgetData';

/**
 * Activity/Uptime/Task chains retain their UI-first fixtures. Fleet reads real
 * bridge metadata; each bridge owns independent live settings/catalog queries.
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
      // Settings, catalog and identity failures remain local to each bridge row.
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/bridges');
          const rows = Array.isArray(data) ? data : data?.bridges || [];
          return { data: rows.map((b: any) => ({
            id: bridgeIdOf(b), label: bridgeLabel(b), online: bridgeIsOnline(b),
            os: String(b.machine_os || b.os || 'Bridge'), agents: 0,
            provider: '', model: '', overrides: [],
          })) };
        } catch (error) { return { error: customQueryError(error) as any }; }
      },
      providesTags: [{ type: 'Bridges', id: 'LIST' }],
    }),
  }),
});
export const {
  useGetHomeActivityQuery, useGetHomeUptimeQuery, useGetHomeTaskChainsQuery,
  useGetHomeChainDetailQuery, useGetHomeFleetQuery,
} = homeApi;
