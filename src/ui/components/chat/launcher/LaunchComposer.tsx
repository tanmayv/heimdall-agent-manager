/**
 * One surface for the conversation composer and the bridge/session picker.
 * Mode changes capture the old visual height before DOM mutation, then resize
 * the surface and fade the incoming body with the shared motion tokens.
 * Initial mount and reduced motion do not animate. Interrupted transitions
 * start from the current visual height and cancel the previous animations.
 *
 * ConversationComposerBody keeps the existing agent/provider toolbar.
 * ShellComposerBody remains available for legacy command-entry callers.
 */
import React, { forwardRef, type ClipboardEvent, type FormEvent, type KeyboardEvent, type ReactNode } from 'react';
import { Badge, Button, Icon, IconButton, Kbd, Text } from '@ui';
import { MessageComposerInput } from '../MessageComposer';
import type { LauncherMode } from './ModeMenu';
import { prefersReducedMotion } from './SentenceToken';

const cx = (...parts: Array<string | false | null | undefined>) => parts.filter(Boolean).join(' ');

export const CONVERSATION_PLACEHOLDER = 'Message the agent';
export const SHELL_PLACEHOLDER = 'Run a command, or leave empty for an interactive shell';
export const SEND_SHORTCUT_HINT = 'Ctrl Enter';

/** The shell footer hint (spec §3.4): the project folder when the shell starts in one, else the home folder. */
export function shellFolderHint(inProjectFolder: boolean, bridgeName: string): string {
  const folder = inProjectFolder ? 'the project folder' : 'the home folder';
  return bridgeName ? `Opens in ${folder} on ${bridgeName}` : `Opens in ${folder}`;
}

export interface LaunchComposerProps {
  mode: LauncherMode;
  /** Dims the composer (45%) and blocks pointer input; sets `aria-disabled`. */
  disabled?: boolean;
  onSubmit?: (event: FormEvent<HTMLFormElement>) => void;
  children: ReactNode;
  debugId?: string;
}

/** Capture the old visual height before React replaces the mode's body. */
class LaunchComposerFrame extends React.Component<LaunchComposerProps & { formRef: React.ForwardedRef<HTMLFormElement> }, {}, number | null> {
  private node: HTMLFormElement | null = null;
  private resize: Animation | null = null;
  private fade: Animation | null = null;

  getSnapshotBeforeUpdate(previous: Readonly<LaunchComposerProps>): number | null {
    return previous.mode !== this.props.mode && this.node ? this.node.getBoundingClientRect().height : null;
  }

  componentDidUpdate(_previous: Readonly<LaunchComposerProps>, _state: {}, height: number | null) {
    if (height === null || !this.node) return;
    this.resize?.cancel();
    this.fade?.cancel();
    if (prefersReducedMotion() || typeof this.node.animate !== 'function') return;
    const styles = window.getComputedStyle(this.node);
    const duration = (token: string, fallback: number) => Number.parseFloat(styles.getPropertyValue(token)) || fallback;
    this.resize = this.node.animate(
      [{ height: height + 'px' }, { height: this.node.getBoundingClientRect().height + 'px' }],
      { duration: duration('--duration-slow', 300), easing: styles.getPropertyValue('--ease-standard').trim() || 'cubic-bezier(0.2, 0.8, 0.2, 1)' },
    );
    const body = this.node.querySelector<HTMLElement>('[data-composer-body]');
    this.fade = body?.animate(
      [{ opacity: 0, transform: 'translateY(var(--space-1-5, 6px))' }, { opacity: 1, transform: 'translateY(0)' }],
      { duration: duration('--duration-base', 200), easing: styles.getPropertyValue('--ease-standard').trim() || 'cubic-bezier(0.2, 0.8, 0.2, 1)' },
    ) ?? null;
  }

  componentWillUnmount() { this.resize?.cancel(); this.fade?.cancel(); }

  render() {
    const { mode, disabled = false, onSubmit, children, debugId = 'new-convo-composer-shell', formRef } = this.props;
    return <form
      ref={(node) => { this.node = node; if (typeof formRef === 'function') formRef(node); else if (formRef) formRef.current = node; }}
      onSubmit={onSubmit ?? ((event) => event.preventDefault())}
      data-debug-id={debugId}
      data-mode={mode}
      aria-disabled={disabled || undefined}
      className={cx(
        'relative overflow-hidden rounded-[var(--radius-xl)] border border-strong bg-subtle',
        mode === 'agent' && 'px-4 pb-3 pt-4',
        'transition-[border-color,box-shadow] duration-fast ease-standard motion-reduce:transition-none',
        'focus-within:border-accent focus-within:shadow-[0_0_0_1px_var(--color-accent)]',
        disabled && 'pointer-events-none opacity-[.45]',
      )}
    >
      <div key={mode} data-composer-body={mode} className={cx('flex flex-col', mode === 'agent' && 'gap-3')}>{children}</div>
    </form>;
  }
}

export const LaunchComposer = forwardRef<HTMLFormElement, LaunchComposerProps>((props, ref) => <LaunchComposerFrame {...props} formRef={ref} />);

export interface ConversationComposerBodyProps {
  mobile: boolean;
  inputRef?: React.Ref<HTMLTextAreaElement>;
  draft: string;
  onDraftChange: (value: string) => void;
  /** Ctrl/Cmd+Enter. */
  onSubmitShortcut: (event: KeyboardEvent<HTMLTextAreaElement>) => void;
  onPaste?: (event: ClipboardEvent<HTMLTextAreaElement>) => void;
  inputDisabled?: boolean;
  /** Attachment rows, shown between the field and the footer. */
  attachments?: ReactNode;
  onAttach: () => void;
  attachDisabled?: boolean;
  /** The agent chip (`AgentMenu`). */
  agentChip: ReactNode;
  /** The provider + model chip (`RuntimeMenu`). */
  runtimeChip: ReactNode;
  sendDisabled: boolean;
}

export function ConversationComposerBody({
  mobile,
  inputRef,
  draft,
  onDraftChange,
  onSubmitShortcut,
  onPaste,
  inputDisabled,
  attachments,
  onAttach,
  attachDisabled,
  agentChip,
  runtimeChip,
  sendDisabled,
}: ConversationComposerBodyProps) {
  return (
    <>
      <MessageComposerInput
        ref={inputRef}
        mobile={mobile}
        appearance="launch"
        debugId="new-convo-composer-input"
        aria-label={CONVERSATION_PLACEHOLDER}
        placeholder={CONVERSATION_PLACEHOLDER}
        value={draft}
        disabled={inputDisabled}
        onChange={(event) => onDraftChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
            event.preventDefault();
            onSubmitShortcut(event);
          }
        }}
        onPaste={onPaste}
      />
      {attachments}
      {/* One row that never wraps (§3.7, like the classic composer toolbar): the attach
          and send buttons keep their size and the two chips shrink and truncate. */}
      <div data-debug-id="new-convo-composer-toolbar" className="flex min-w-0 flex-nowrap items-center gap-1.5 md:gap-2">
        <IconButton
          icon="plus"
          label="Attach files"
          size={mobile ? 'md' : 'sm'}
          className="shrink-0"
          data-debug-id="new-convo-attach-btn"
          disabled={attachDisabled}
          onClick={onAttach}
        />
        {agentChip}
        {/* One right-aligned group holding the provider chip and the send button. */}
        <div data-debug-id="new-convo-composer-send-group" className="ml-auto flex min-w-0 items-center gap-1.5 md:gap-2">
          {mobile ? null : <Kbd data-debug-id="new-convo-send-shortcut" className="shrink-0">{SEND_SHORTCUT_HINT}</Kbd>}
          {runtimeChip}
          <IconButton
            type="submit"
            icon="arrow-up"
            label="Start conversation"
            variant="primary"
            size={mobile ? 'md' : 'sm'}
            className="shrink-0"
            data-debug-id="new-convo-composer-send-btn"
            disabled={sendDisabled}
          />
        </div>
      </div>
    </>
  );
}

export interface ShellComposerBodyProps {
  mobile: boolean;
  inputRef?: React.Ref<HTMLTextAreaElement>;
  command: string;
  onCommandChange: (value: string) => void;
  inputDisabled?: boolean;
  /** True when the shell starts in the project's folder on the bridge. */
  inProjectFolder: boolean;
  bridgeName: string;
  onOpen: () => void;
  openDisabled: boolean;
  busy?: boolean;
  openRef?: React.Ref<HTMLButtonElement>;
}

export function ShellComposerBody({
  mobile,
  inputRef,
  command,
  onCommandChange,
  inputDisabled,
  inProjectFolder,
  bridgeName,
  onOpen,
  openDisabled,
  busy = false,
  openRef,
}: ShellComposerBodyProps) {
  return (
    <>
      <div className="flex min-w-0 items-start gap-2">
        <Text as="span" role="code" tone="accent" aria-hidden="true" data-debug-id="new-shell-prompt">$</Text>
        <MessageComposerInput
          ref={inputRef}
          mobile={mobile}
          appearance="launch"
          mono
          debugId="new-shell-command"
          aria-label="Command to run"
          placeholder={SHELL_PLACEHOLDER}
          value={command}
          disabled={inputDisabled}
          onChange={(event) => onCommandChange(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              if (!openDisabled) onOpen();
            }
          }}
        />
      </div>
      <div data-debug-id="new-shell-toolbar" className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge data-debug-id="new-shell-kind" className="font-mono">zsh</Badge>
        <Text as="span" role="body-sm" tone="muted" className="m-0 min-w-0" data-debug-id="new-shell-hint">
          {shellFolderHint(inProjectFolder, bridgeName)}
        </Text>
        <span className="flex-1" aria-hidden="true" />
        <Button
          ref={openRef}
          variant="primary"
          size="sm"
          leading={<Icon name="terminal" size="md" />}
          loading={busy}
          disabled={openDisabled}
          onClick={onOpen}
          data-debug-id="new-shell-open"
          className="active:scale-[.96] motion-reduce:active:scale-100 max-md:min-h-11"
        >
          {busy ? 'Opening…' : 'Open shell'}
        </Button>
      </div>
    </>
  );
}

export default LaunchComposer;
