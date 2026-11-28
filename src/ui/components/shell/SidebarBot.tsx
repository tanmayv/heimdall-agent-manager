import { Icon, StatusDot } from '@ui';
import { useGetBotQuery, useGetBotWebConversationQuery } from '../../api/endpoints/bots';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { buildRouteHash } from '../../utils/appLocation';
import { navigateToHash, parseConversationIdsFromRoute } from '../../utils/conversationUrl';
import { BOTS_EXPERIMENT_KEY, resolveExperimentFlag } from '../settings/experimentFlags';
import { resolveBotStatusLabel } from '../settings/botsView';
import { isBotRunning } from '../bots/botChatModel';

export const BOT_CHAT_ROUTE = '/bot';

export interface SidebarBotProps {
  currentPath: string;
  onNavigate?: () => void;
}

/**
 * REQ-WEB-4: the owner's bot in the navigation rail. Renders nothing unless the
 * bots experiment is on and the bot exists; it never asks for the bot otherwise.
 * Freshness comes from the shared `Bot` tag (bot_changed events) and the chat
 * page's poll; the rail adds no timer of its own.
 */
export function SidebarBot({ currentPath, onNavigate }: SidebarBotProps) {
  const flags = useFetchExperimentsQuery();
  const enabled = resolveExperimentFlag(flags.data?.flags, BOTS_EXPERIMENT_KEY) === 'enabled';
  const query = useGetBotQuery(undefined, { skip: !enabled });
  const bot = enabled ? query.currentData : undefined;
  const rollout = useGetBotWebConversationQuery(undefined, { skip: !enabled });
  const fresh = enabled && !rollout.isError ? rollout.currentData : undefined;
  if (!bot && !fresh) return null;
  const running = bot ? isBotRunning(bot.status) : false;
  const bridge = bot?.advanced.bridge_label || bot?.advanced.bridge_id || 'No bridge';
  const providerId = bot?.advanced.provider ?? '';
  const provider = ({ claude: 'Claude Code', codex: 'Codex' } as Record<string, string>)[providerId]
    || providerId || 'No provider';
  const active = currentPath === BOT_CHAT_ROUTE || Boolean(fresh?.enabled &&
    parseConversationIdsFromRoute(currentPath).ids.includes(fresh.agent_instance_id));
  const open = (event: React.MouseEvent<HTMLAnchorElement>) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    navigateToHash(buildRouteHash(BOT_CHAT_ROUTE, ''));
    onNavigate?.();
  };
  return (
    <section aria-label="Bot" data-debug-id="sidebar-bot" className="mt-4 min-w-0 border-t border-subtle pt-3">
      <h2 className="mb-2 px-2.5 text-xs font-semibold text-muted">Bot</h2>
      <a href={buildRouteHash(BOT_CHAT_ROUTE, '')} onClick={open} data-debug-id="sidebar-bot-row"
        aria-current={active ? 'page' : undefined} title="Chat with your bot"
        className={`flex min-h-11 min-w-0 items-center gap-2 rounded-xl px-2.5 py-2 hover:bg-neutral-soft ${active ? 'bg-neutral-soft font-semibold' : ''}`}>
        <Icon name="bot" size={16} className="shrink-0 text-muted" />
        <span className="min-w-0 flex-1">
          <span data-debug-id="sidebar-bot-name" className="block truncate text-[13px] font-medium text-primary">{bot?.display_name || 'Bot'}</span>
          {fresh?.generation ? <span className="text-xs text-muted">{fresh.enabled ? 'Shared conversation' : 'Shared conversation paused'}</span>
          : bot ? <span data-debug-id="sidebar-bot-status" className="flex min-w-0 items-center gap-1.5 text-xs text-muted">
            <StatusDot size="sm" tone={running ? 'success' : 'neutral'} pulse={bot.status === 'working' || bot.status === 'starting'}
              label={resolveBotStatusLabel(bot.status)} />
            <span className="sr-only">{running ? 'Running on ' : 'Stopped on '}</span>
            <span data-debug-id="sidebar-bot-placement" className="min-w-0 truncate">{bridge} · {provider}</span>
          </span> : null}
        </span>
      </a>
    </section>
  );
}
