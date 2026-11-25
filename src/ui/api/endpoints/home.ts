import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, customQueryError } from '../cookieFetch';
import { bridgeIdOf, bridgeIsOnline, bridgeLabel } from '../../utils/bridgeLaunchOptions';
import {
  activityFixture, uptimeFixture,
} from '../../components/home/homeWidgetFixtures';
import { activityFromWire, uptimeFromWire, type ActivityData, type ActivityMetric, type FleetBridge, type UptimeData } from '../../components/home/widgetData';

/**
 * Activity/Uptime retain their UI-first fixtures. Fleet reads real
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
  useGetHomeActivityQuery, useGetHomeUptimeQuery, useGetHomeFleetQuery,
} = homeApi;
