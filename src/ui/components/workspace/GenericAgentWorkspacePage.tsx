import ChatComposer from '../chat/ChatComposer';
import ChatHeader from '../chat/ChatHeader';
import ChatMessageList from '../chat/ChatMessageList';
import ChatWorkBanner from '../chat/ChatWorkBanner';
import type { WorkspaceGenericAgentContext } from './types';

export default function GenericAgentWorkspacePage({
  context,
}: {
  context: WorkspaceGenericAgentContext;
}) {
  return (
    <div data-debug-id="generic-agent-page" className={context.className || 'flex h-full min-h-0 flex-col bg-[#090909] text-zinc-100'}>
      <ChatHeader {...context.header} />
      <div data-debug-id="generic-agent-page-body" className={context.bodyClassName || 'min-h-0 flex-1 overflow-hidden px-5 py-5'}>
        <div className={context.bodyInnerClassName || 'mx-auto flex h-full max-w-[760px] flex-col'}>
          <ChatMessageList {...context.chat} />
        </div>
      </div>
      {(context.workBanner || context.composer) ? (
        <div data-debug-id="generic-agent-page-composer-region" className={context.composerContainerClassName || 'px-5 pb-[18px] pt-3'}>
          <div className={context.bodyInnerClassName || 'mx-auto flex h-full max-w-[760px] flex-col'}>
            {context.workBanner ? <ChatWorkBanner {...context.workBanner} /> : null}
            {context.composer ? <ChatComposer {...context.composer} /> : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}
