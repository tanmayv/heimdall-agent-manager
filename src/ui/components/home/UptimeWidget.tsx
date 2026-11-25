import { Text, Link } from '@ui';
import { useGetHomeUptimeQuery } from '../../api/endpoints/home';
import { loadMockUptime } from './homeWidgetFixtures';
import { dateFromKey, type UptimeData, type UptimeDay, type WidgetLoader, type WidgetResource } from './widgetData';
import { Legend, useWidgetData, WidgetHeading, WidgetStat, WidgetState } from './WidgetShared';

export function uptimeDayLabel(day: UptimeDay): string {
  const date = dateFromKey(day.date).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });
  const minutes = Math.round(day.downSeconds / 60);
  const duration = minutes >= 60 ? `${Math.floor(minutes / 60)}h ${minutes % 60}m` : `${minutes}m`;
  return `${date}: ${day.state === 'none' ? 'Not enrolled yet' : day.state === 'up' ? 'Up all day' : `Down ${duration}`}`;
}
export function UptimeWidget({ resource: supplied, load }: { resource?: WidgetResource<UptimeData>; load?: WidgetLoader<UptimeData> } = {}) {
  const query = useGetHomeUptimeQuery(undefined, { skip: Boolean(supplied || load) });
  const endpointResource: WidgetResource<UptimeData> = query.isError ? { status: 'error', message: 'Unable to load uptime' } : query.data ? { status: 'ready', data: query.data } : { status: 'loading' };
  const custom = useWidgetData(load || loadMockUptime, supplied || (load ? undefined : endpointResource));
  const { resource } = custom;
  const retry = load ? custom.retry : () => { void query.refetch(); };
  const data = resource.status === 'ready' ? resource.data : undefined;
  return <section data-debug-id="home-widget-uptime" className="home-uptime" aria-labelledby="home-uptime-title">
    <WidgetHeading id="home-uptime-title" title="Uptime"><Text role="body-sm" tone="muted">{data && data.total > 0 ? data.connected === data.total ? 'All bridges connected' : `${data.connected} bridges connected` : ''}</Text></WidgetHeading>
    <div className="home-card">
      {resource.status !== 'ready' ? <WidgetState status={resource.status} name="Uptime" message={resource.status === 'error' ? resource.message : undefined} onRetry={retry} />
        : !data!.bridges.length ? <div className="home-widget-state"><Text role="body-sm" tone="muted">No bridges yet</Text><Link data-debug-id="home-uptime-add-bridge" href="#/settings/bridges">Add bridge</Link></div> : <>
          <div className="home-uptime-stats"><WidgetStat label="Connected now" value={`${data!.connected} of ${data!.total}`} /><WidgetStat label="Fleet uptime, 30 days" value={`${data!.uptimePercent.toFixed(2)}%`} /></div>
          {data!.bridges.map((bridge) => <div className="home-uptime-bridge" key={bridge.id}>
            <div className="home-row"><Text role="code-sm">{bridge.label}</Text><Text role="label">{bridge.uptimePercent.toFixed(2).replace('.00', '')}%</Text></div>
            <div className="home-uptime-strip" role="img" aria-label={`${bridge.label}: ${bridge.uptimePercent}% uptime over 30 days, ${bridge.incidents} incidents.`}>
              {bridge.days.map((day) => <span key={day.date} tabIndex={0} data-debug-id={`home-uptime-day-${bridge.id}-${day.date}`} className={`home-uptime-bar home-uptime-${day.state}`} aria-label={uptimeDayLabel(day)} data-tooltip={uptimeDayLabel(day)}><span className="home-bar-tooltip" aria-hidden="true">{uptimeDayLabel(day)}</span></span>)}
            </div>
            <div className="home-row"><Text role="caption" tone="muted"><i className={`home-presence-dot ${bridge.online ? 'is-online' : ''}`} />{bridge.online ? `Connected ${bridge.connectedFor}` : 'Disconnected'}</Text><Text role="caption" tone="muted">{bridge.incidents ? `${bridge.incidents} incident${bridge.incidents === 1 ? '' : 's'}` : 'No incidents'}</Text></div>
          </div>)}
          <footer className="home-widget-footer"><Legend items={[{ label: 'Up', tone: 'success' }, { label: 'Partly down', tone: 'warning' }, { label: 'Down', tone: 'danger' }]} /><Text role="caption" tone="muted">30 days ago → today</Text></footer>
        </>}
    </div>
  </section>;
}
export default UptimeWidget;
