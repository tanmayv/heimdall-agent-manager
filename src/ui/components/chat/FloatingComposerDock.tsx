import { forwardRef, type ComponentProps } from 'react';
import { MessageComposerMorphShell } from './MessageComposer';

// The gaps around the card pass touches through to the transcript. Keep the
// max-w-4xl card plus a px-3 gutter, independently of the keyboard geometry.
export const FloatingComposerDock = forwardRef<HTMLDivElement, ComponentProps<'div'>>(
  function FloatingComposerDock({ children, ...props }, ref) {
    return <div {...props} ref={ref} data-floating="true"
      className="ui-float-dock absolute inset-x-0 bottom-0 z-20 mx-auto w-full max-w-[calc(56rem+1.5rem)]">
      <div aria-hidden="true" className="ui-frost-tail" />
      {children}
    </div>;
  },
);

export const FloatingComposerForm = forwardRef<HTMLFormElement, ComponentProps<'form'> & { mobile: boolean; raised?: boolean }>(
  function FloatingComposerForm({ mobile, raised, children, ...props }, ref) {
    return <form {...props} ref={ref}
      className={`w-full max-w-[calc(56rem+1.5rem)] mx-auto px-3 ${raised ? 'pt-5' : 'pt-2'} ${mobile ? 'ui-float-dock-pad' : 'pb-4'}`}>
      {children}
    </form>;
  },
);

export function FloatingComposerCard({ leading, debugPrefix, ...props }: ComponentProps<typeof MessageComposerMorphShell>) {
  return <MessageComposerMorphShell {...props} debugPrefix={debugPrefix}
    className="ui-frost-card isolate rounded-[28px] border px-5"
    leading={<>
      <div data-debug-id={`${debugPrefix}-composer-frost`} aria-hidden="true" className="ui-frost-gradient -z-10"><span /><span /><span /></div>
      {leading}
    </>} />;
}
