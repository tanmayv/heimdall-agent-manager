// origin/main's ticket decision block (REQ-T3, REQ-T6) behind a props seam:
// the caller supplies the submission (summary, head, changed files) and the
// actions, so a Bridge-owned chain feeds it owner-local reads and commands
// instead of the Hub task facets and task actions.

import { useState, type ReactNode } from 'react';
import { Alert, Badge, Button, Text, Textarea } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { DecryptedMarkdown } from '../vault';
import { describeHold, taskHold } from './taskV2Types';
import { awaitingYourReview, blockedOnYou, isSupersededReview, youApproved } from './taskActions';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import type { TaskNames } from './taskNames';
import { blockReasonText, isRework, ticketAsk } from './ticketModel';
import { TicketCard } from './TicketCard';

export interface TicketDecisionActions {
  busy: boolean;
  release: () => Promise<boolean>;
  /** Absent when tickets are never drafts (Bridge-owned chains publish on create). */
  publish?: () => Promise<boolean>;
  answer: (body: string) => Promise<boolean>;
  approve: () => Promise<boolean>;
  requestChanges: (body: string) => Promise<boolean>;
  comment: (body: string) => Promise<boolean>;
}

/** The attempt under review, as its submission reads. */
export interface TicketDecisionSubmission { summary?: string; head?: string; files?: string[] }

/** A text box with its action row; replaces the Hub TaskComposer (no attachments). */
function DecisionComposer({ debugId, placeholder, disabled, requireText = false, renderActions }: {
  debugId: string; placeholder: string; disabled: boolean; requireText?: boolean;
  renderActions: (a: { body: string; canSend: boolean; reset: () => void }) => ReactNode;
}) {
  const [body, setBody] = useState('');
  const canSend = !disabled && (!requireText || Boolean(body.trim()));
  return (
    <div className="flex flex-col gap-2" data-debug-id={debugId}>
      <Textarea size="sm" rows={3} aria-label={placeholder} placeholder={placeholder} disabled={disabled} value={body} onChange={setBody} data-debug-id={`${debugId}-input`} />
      <div className="flex flex-wrap items-center justify-end gap-2">{renderActions({ body, canSend, reset: () => setBody('') })}</div>
    </div>
  );
}

export function TicketDecisionBlock({ task, actions, names, now, submission, reviewable }: {
  task: TaskWire; actions: TicketDecisionActions; names: TaskNames; now: number;
  submission?: TicketDecisionSubmission;
  /** Offer the verdict even when the gate does not wait on you (the owner may review any submission). */
  reviewable?: boolean;
}) {
  const ask = ticketAsk(task);
  const hold = taskHold(task);
  const userApproved = youApproved(task);
  const reviewing = awaitingYourReview(task) || userApproved || Boolean(reviewable);
  const b: any = task.blocked_on || {};

  if (hold && !(b.kind === 'agent_not_running' || b.kind === 'dispatch')) {
    return (
      <TicketCard title={hold.checkpoint_requested ? 'Held · checkpoint requested' : 'Held'} debugId="task-hold-block" className="border-warning/40">
        {hold.reason ? <DecryptedMarkdown source={hold.reason} compact copyAll={false} data-debug-id="task-hold-reason" /> : null}
        <Text as="p" role="body-sm" tone="muted" data-debug-id="task-hold-meta">
          {[describeHold(hold, now, names), hold.checkpoint_requested ? 'the current holder was asked to hand off' : '', 'no new lease until released'].filter(Boolean).join(' · ')}
        </Text>
        <div className="mt-3">
          <Button size="sm" variant="secondary" disabled={actions.busy} data-debug-id="task-hold-release-btn" onClick={() => void actions.release()}>
            Release hold
          </Button>
        </div>
      </TicketCard>
    );
  }
  if (ask === 'agent_down') {
    return (
      <TicketCard title="Agent not running" debugId="ticket-view-agent-down" className="border-danger/40">
        <Text as="p" role="body-sm" className="text-primary">{String(b.reason || 'The agent could not start.')}</Text>
        <Text as="p" role="caption" tone="muted">Check the agent's bridge, provider and model. Updating its fleet settings retries the start.</Text>
      </TicketCard>
    );
  }
  if (ask === 'publish' && actions.publish) {
    const publish = actions.publish;
    return (
      <TicketCard title="Not published" debugId="ticket-view-draft">
        <Text as="p" role="body-sm" tone="muted">Agents can't see this ticket until you publish it.</Text>
        <div className="mt-3">
          <Button size="sm" variant="primary" disabled={actions.busy} onClick={() => void publish()} data-debug-id="ticket-view-publish-btn">
            Publish
          </Button>
        </div>
      </TicketCard>
    );
  }
  if (blockedOnYou(task) && !hold) {
    const question = String(b.question || blockReasonText(b.reason) || b.message || '').trim();
    return (
      <TicketCard title="Your answer" debugId="answer-blocker-block" className="border-warning/40">
        {question ? (
          <blockquote data-debug-id="answer-question" className="mb-3 border-l-2 border-warning pl-3 text-body-sm text-primary">
            <DecryptedMarkdown source={question} compact copyAll={false} />
          </blockquote>
        ) : (
          <Text as="p" role="body-sm" tone="muted">The agent is waiting on you but did not say what it needs. Check the latest comments, or ask it.</Text>
        )}
        <DecisionComposer
          debugId="answer-composer"
          placeholder="Type your answer."
          disabled={actions.busy}
          requireText
          renderActions={({ body, canSend, reset }) => (
            <Button size="sm" variant="primary" disabled={!canSend} onClick={async () => { if (await actions.answer(body)) reset(); }} data-debug-id="answer-send-btn">
              Send answer
            </Button>
          )}
        />
      </TicketCard>
    );
  }
  if (!reviewing) return null;

  const rework = isRework(task);
  const req = task.requirements;
  const submitted = Number(req?.submitted_revision) || 0;
  const current = Number(req?.revision) || 0;
  const files = submission?.files ?? [];
  const votes = (task.reviews || []).filter((r) => !isSupersededReview(r) && r.reviewer !== 'user');
  const worker = task.brief?.assignee ? names.agent(String(task.brief.assignee)) : 'The worker';
  return (
    <TicketCard title="Your review" aside={rework ? <Badge tone="warning">Waiting for rework</Badge> : undefined} debugId="your-review-block" className="border-warning/40">
      <div className="flex flex-col gap-3">
        {rework && (
          <div data-debug-id="ticket-view-rework-notice">
            <Alert tone="warning" title="The requirements changed after this was submitted.">
              {worker} submitted attempt {task.attempt_no || 1} against rev {submitted || current - 1}; the requirements are now rev {current}, so this submission can't be approved. {worker} has been asked to rework it.
            </Alert>
          </div>
        )}
        {submission?.summary && <DecryptedMarkdown source={submission.summary} compact copyAll={false} data-debug-id="your-review-summary" />}
        {(files.length > 0 || submission?.head) && (
          <Text role="caption" tone="muted" data-debug-id="your-review-head">
            {files.length > 0 ? `${files.length} file${files.length === 1 ? '' : 's'} changed` : 'Submitted'}
            {submission?.head ? <> · head <Text as="code" role="code-sm">{submission.head.slice(0, 7)}</Text></> : null}
          </Text>
        )}
        {votes.length > 0 && (
          <div className="flex flex-col gap-1" data-debug-id="ticket-view-votes">
            <Text as="span" role="overline" tone="faint">Votes</Text>
            <ul className="flex flex-wrap gap-x-4 gap-y-1">
              {votes.map((v, i) => {
                const label = names.participant(v.reviewer) || names.instance(v.reviewer_instance_id) || 'A reviewer';
                return (
                  <li key={`${v.reviewer}-${v.role}-${i}`} className="inline-flex items-center gap-1.5 text-body-sm">
                    <TicketAgentAvatar name={label} state="idle" />
                    <span className={rework ? 'text-faint line-through' : 'text-primary'}>{label}</span>
                    <span className="text-muted">{v.verdict === 'approve' ? 'approved' : 'requested changes'}</span>
                    {rework && <Badge tone="neutral">for rev {submitted || current - 1} · no longer counts</Badge>}
                  </li>
                );
              })}
            </ul>
          </div>
        )}
        <DecisionComposer
          debugId="your-review-composer"
          placeholder={rework ? 'Leave a note for the worker about the rework.' : 'What should change? Needed to request changes.'}
          requireText
          disabled={actions.busy}
          renderActions={({ body, canSend, reset }) => (
            <>
              {rework && <Text role="caption" tone="muted">Approve unlocks when the worker resubmits against rev {current}.</Text>}
              {userApproved ? (
                <Text role="caption" tone="muted" data-debug-id="your-review-approved">You approved</Text>
              ) : (
                <Button
                  size="sm"
                  variant="primary"
                  // Approve sends no note, so it waits until a typed one is sent or cleared.
                  disabled={actions.busy || rework || Boolean(body.trim())}
                  title={body.trim() && !rework ? 'Send your note with Request changes, or clear it to approve' : undefined}
                  onClick={() => void actions.approve()}
                  data-debug-id="ticket-view-approve-btn"
                >
                  Approve
                </Button>
              )}
              <Button
                size="sm"
                variant="secondary"
                disabled={!canSend}
                data-debug-id="ticket-view-request-changes-btn"
                onClick={async () => {
                  if (rework ? await actions.comment(body) : await actions.requestChanges(body)) reset();
                }}
              >
                {rework ? 'Post comment' : 'Request changes'}
              </Button>
            </>
          )}
        />
      </div>
    </TicketCard>
  );
}
