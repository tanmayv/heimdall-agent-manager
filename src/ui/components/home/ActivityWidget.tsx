import { useCallback, useState } from 'react';
import { Button, Text } from '@ui';
import { useGetHomeActivityQuery } from '../../api/endpoints/home';
import { loadMockActivity } from './homeWidgetFixtures';
import { ACTIVITY_METRICS, activityLevel, dateFromKey, type ActivityData, type ActivityMetric, type WidgetResource } from './widgetData';
import { useWidgetData, WidgetState, WidgetStat } from './WidgetShared';

export interface ActivityWidgetProps {
  resource?: WidgetResource<ActivityData>;
  load?: (metric: ActivityMetric, signal: AbortSignal) => Promise<ActivityData>;
}
export function ActivityWidget({ resource: supplied, load }: ActivityWidgetProps = {}) {
  const [metric, setMetric] = useState<ActivityMetric>('tasks_completed');
  const query = useGetHomeActivityQuery(metric, { skip: Boolean(supplied || load) });
  const loader = useCallback((signal: AbortSignal) => (load || loadMockActivity)(metric, signal), [load, metric]);
  const endpointResource: WidgetResource<ActivityData> = query.isError ? { status: 'error', message: 'Unable to load activity' } : query.currentData ? { status: 'ready', data: query.currentData } : { status: 'loading' };
  const custom = useWidgetData(loader, supplied || (load ? undefined : endpointResource));
  const { resource } = custom;
  const retry = load ? custom.retry : () => { void query.refetch(); };
  const [hovered, setHovered] = useState<string | null>(null);
  const selected = ACTIVITY_METRICS.find((item) => item.id === metric)!;
  const data = resource.status === 'ready' ? resource.data : undefined;
  const day = data?.days.find((item) => item.date === hovered) || data?.days.filter((item) => !item.future).slice(-1)[0];
  const format = (key: string) => dateFromKey(key).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
  return <section data-debug-id="home-widget-activity" className="home-activity home-card" aria-labelledby="home-activity-title">
    <header className="home-activity-header">
      <div><Text as="h2" id="home-activity-title" role="heading">Activity</Text><Text role="body-sm" tone="muted">{selected.label} per day, last 12 months</Text></div>
      <div className="home-metric-switch" role="group" aria-label="Activity metric">{ACTIVITY_METRICS.map((item) =>
        <Button key={item.id} size="sm" variant="ghost" aria-pressed={metric === item.id} data-debug-id={`home-activity-metric-${item.id.replace(/_/g, '-')}`} onClick={() => { setMetric(item.id); setHovered(null); }}>{item.label}</Button>)}</div>
    </header>
    {resource.status !== 'ready' ? <WidgetState status={resource.status} name="Activity" message={resource.status === 'error' ? resource.message : undefined} onRetry={retry} /> : <>
      <div className="home-activity-stats">
        <WidgetStat label={data!.kind === 'counter' ? 'Last 12 months' : 'Daily average'} value={data!.kind === 'counter' ? data!.summary.total : data!.summary.average?.toFixed(1)} detail={selected.unit} />
        <WidgetStat label="Busiest day" value={data!.summary.best.value} detail={data!.summary.best.date ? format(data!.summary.best.date) : 'No activity yet'} />
        <WidgetStat label="Active days" value={data!.summary.activeDays} detail="days with activity" />
        <WidgetStat label="Current streak" value={`${data!.summary.streakDays} days`} detail="through today" />
      </div>
      {!data!.summary.activeDays && <Text role="body-sm" tone="muted">No activity yet</Text>}
      <div className="home-heatmap-scroll"><svg className="home-heatmap" viewBox="0 0 831 132" role="img" aria-label={`53 weeks of ${selected.label.toLowerCase()}: ${data!.summary.activeDays} active days, current streak ${data!.summary.streakDays} days.`} tabIndex={0} data-debug-id="home-activity-heatmap"
        onMouseLeave={() => setHovered(null)} onBlur={() => setHovered(null)}
        onKeyDown={(event) => {
          if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
          event.preventDefault();
          const elapsed = data!.days.filter((item) => !item.future);
          const current = Math.max(0, elapsed.findIndex((item) => item.date === (day?.date)));
          const delta = event.key === 'ArrowLeft' ? -7 : event.key === 'ArrowRight' ? 7 : event.key === 'ArrowUp' ? -1 : 1;
          setHovered(elapsed[Math.max(0, Math.min(elapsed.length - 1, current + delta))]?.date || null);
        }}>
        {[1, 3, 5].map((row) => <text key={row} x="0" y={34 + row * 15} className="home-chart-label">{['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][row]}</text>)}
        {data!.days.map((item, index) => {
          const date = dateFromKey(item.date);
          return <g key={item.date}>
            {date.getDate() <= 7 && date.getDay() === 0 && <text x={32 + Math.floor(index / 7) * 15} y="14" className="home-chart-label">{date.toLocaleDateString(undefined, { month: 'short' })}</text>}
            <rect x={32 + Math.floor(index / 7) * 15} y={22 + index % 7 * 15} width="12" height="12" rx="3"
              className={`home-heat-cell home-heat-level-${activityLevel(item.value, data!.levels)}`} opacity={item.future ? 0 : 1}
              onMouseEnter={() => !item.future && setHovered(item.date)}><title>{format(item.date)}: {item.future ? 'Future day' : `${item.value} ${selected.unit}`}</title></rect>
          </g>;
        })}
      </svg></div>
      <footer className="home-activity-footer"><Text role="caption" tone="muted" aria-live="polite">{day ? <><strong>{day.value}</strong> {selected.unit} · {format(day.date)}</> : 'No activity yet'}</Text><div className="home-heat-key"><Text role="caption" tone="muted">Less</Text>{[0, 1, 2, 3, 4].map((level) => <i key={level} className={`home-heat-cell home-heat-level-${level}`} />)}<Text role="caption" tone="muted">More</Text></div></footer>
    </>}
  </section>;
}
export default ActivityWidget;
