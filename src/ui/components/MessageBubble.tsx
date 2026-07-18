import { useState, memo, useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { updateUrlParams } from './useUrlParams';
import { sendMessageToSelectedAgent } from '../store/chatSlice';
import { selectCachedTaskById } from '../api/taskCache';
import { tasksApi } from '../api/endpoints/tasks';
import { useFetchChainQuery } from '../api/endpoints/workspace';
import { useFetchMemoryQuery, useListMemoryQuery } from '../api/endpoints/memory';
import Markdown from './Markdown';
import ChatHoverCopyButton from './ChatHoverCopyButton';

function isSafeUrl(url: string) {
  const trimmed = url.trim();
  return /^(https?:|mailto:)/i.test(trimmed) || trimmed.startsWith('/') || trimmed.startsWith('#');
}

function splitTrailingUrlPunctuation(url: string) {
  const match = url.match(/^(.+?)([.,!?;:]+)?$/);
  return { href: match?.[1] || url, trailing: match?.[2] || '' };
}

function renderInlineMarkdown(text: string, keyPrefix: string) {
  const nodes = [];
  const pattern = /(`[^`]+`|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|https?:\/\/[^\s<>()]+|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*]+)\*|_([^_]+)_)/g;
  let lastIndex = 0;
  let match;

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > lastIndex) nodes.push(text.slice(lastIndex, match.index));
    const token = match[0];
    const key = `${keyPrefix}-${match.index}`;

    if (token.startsWith('`')) {
      nodes.push(<code key={key}>{token.slice(1, -1)}</code>);
    } else if (match[2] && match[3]) {
      const href = match[3];
      nodes.push(isSafeUrl(href) ? (
        <a key={key} href={href} target="_blank" rel="noreferrer noopener">
          {renderInlineMarkdown(match[2], `${key}-link`)}
        </a>
      ) : match[2]);
    } else if (/^https?:\/\//i.test(token)) {
      const { href, trailing } = splitTrailingUrlPunctuation(token);
      nodes.push(isSafeUrl(href) ? (
        <a key={key} href={href} target="_blank" rel="noreferrer noopener">
          {href}
        </a>
      ) : token);
      if (trailing) nodes.push(trailing);
    } else if (match[4] || match[5]) {
      nodes.push(<strong key={key}>{renderInlineMarkdown(match[4] || match[5], `${key}-strong`)}</strong>);
    } else if (match[6] || match[7]) {
      nodes.push(<em key={key}>{renderInlineMarkdown(match[6] || match[7], `${key}-em`)}</em>);
    }

    lastIndex = pattern.lastIndex;
  }

  if (lastIndex < text.length) nodes.push(text.slice(lastIndex));
  return nodes;
}

function splitTableRow(line: string) {
  return line
    .trim()
    .replace(/^\|/, '')
    .replace(/\|$/, '')
    .split('|')
    .map((cell) => cell.trim());
}

function isTableSeparator(line: string) {
  const cells = splitTableRow(line);
  return cells.length > 1 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function looksLikeTableRow(line: string) {
  const trimmed = line.trim();
  return trimmed.includes('|') && splitTableRow(trimmed).length > 1;
}

function renderHeading(level: number, key: string, children: ReturnType<typeof renderInlineMarkdown>) {
  if (level === 1) return <h1 key={key}>{children}</h1>;
  if (level === 2) return <h2 key={key}>{children}</h2>;
  if (level === 3) return <h3 key={key}>{children}</h3>;
  if (level === 4) return <h4 key={key}>{children}</h4>;
  if (level === 5) return <h5 key={key}>{children}</h5>;
  return <h6 key={key}>{children}</h6>;
}

function MarkdownContent({ text, className = '' }: { text: string; className?: string }) {
  console.log('[Render] MarkdownContent');
  return <Markdown source={text} compact copyAll={false} className={`text-sm leading-6 ${className}`} />;
}

function parseReferences(text: string) {
  const refs: Array<{ type: 'task' | 'chain' | 'memory' | 'proposal'; id: string }> = [];
  if (typeof text !== 'string') return refs;
  
  const pattern = /\b(task-[a-f0-9]+|chain-[a-f0-9]+|mem_\d+|proposal_\d+)\b/gi;
  let match;
  const seen = new Set<string>();
  while ((match = pattern.exec(text)) !== null) {
    const refStr = match[1].toLowerCase();
    if (seen.has(refStr)) continue;
    seen.add(refStr);
    
    if (refStr.startsWith('task-')) {
      refs.push({ type: 'task', id: refStr });
    } else if (refStr.startsWith('chain-')) {
      refs.push({ type: 'chain', id: refStr });
    } else if (refStr.startsWith('mem_')) {
      refs.push({ type: 'memory', id: refStr });
    } else if (refStr.startsWith('proposal_')) {
      refs.push({ type: 'proposal', id: refStr });
    }
  }
  return refs;
}

function EntityCard({ id, type, session }: { id: string; type: 'task' | 'chain' | 'memory' | 'proposal'; session: any }) {
  const dispatch = useDispatch<any>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const chainQuery = useFetchChainQuery({ chainId: id }, { skip: type !== 'chain' || !session?.clientToken });
  const memoryDetailQuery = useFetchMemoryQuery({ memoryId: id }, { skip: type !== 'memory' || !session?.clientToken });
  const memoryListQuery = useListMemoryQuery(undefined, { skip: type !== 'proposal' || !session?.clientToken });
  // Retrieve selector based on type
  const storeEntity = useSelector((state: any) => {
    if (type === 'task') {
      return selectCachedTaskById(state, id);
    }
    return null;
  });
  const entity = type === 'memory'
    ? memoryDetailQuery.data?.record
    : type === 'proposal'
      ? (memoryListQuery.data?.records || []).find((r: any) => r.proposalId === id || r.memoryId === id)
      : type === 'chain'
        ? chainQuery.data?.chain
        : storeEntity;
  const handleClick = (e: React.MouseEvent) => {
    if (window.getSelection()?.toString()) return;
    if (type === 'task') {
      updateUrlParams({ chainId: entity?.chainId || entity?.chain_id || '', taskId: id, view: 'chain' });
    } else if (type === 'chain') {
      updateUrlParams({ chainId: id, taskId: '', view: 'chain' });
    } else if (type === 'memory' || type === 'proposal') {
      if (entity?.memoryId) {
        updateUrlParams({ memoryId: entity.memoryId, view: 'memory' });
      }
    }
  };
  useEffect(() => {
    if (entity || loading || error || type === 'memory' || type === 'proposal' || type === 'chain') return;

    async function loadEntity() {
      setLoading(true);
      setError(null);
      try {
        if (type === 'task') {
          const res = await (dispatch as any)(tasksApi.endpoints.fetchTask.initiate({ taskId: id }, { subscribe: false, forceRefetch: true })).unwrap();
          if (!res?.task) {
            throw new Error('Task details not found');
          }
        }
      } catch (e: any) {
        console.error(`Failed to load ${type} reference ${id}:`, e);
        setError(e?.message || `Failed to load ${type}`);
      } finally {
        setLoading(false);
      }
    }

    loadEntity();
  }, [id, type, entity, loading, error, session, dispatch]);

  const effectiveLoading = loading || (type === 'chain' && chainQuery.isFetching) || (type === 'memory' && memoryDetailQuery.isFetching) || (type === 'proposal' && memoryListQuery.isFetching);
  const effectiveError = error || ((type === 'chain' && chainQuery.error) || (type === 'memory' && memoryDetailQuery.error) || (type === 'proposal' && memoryListQuery.error) ? `Failed to load ${type}` : null);

  if (effectiveLoading) {
    return (
      <div className="w-full bg-[#141414]/50 border border-[#222] rounded-lg p-3 my-1.5 flex flex-col gap-1 text-xs">
        <div className="flex items-center justify-between">
          <span className="text-[10px] font-bold text-gray-500 uppercase tracking-wider">
            {type} reference
          </span>
          <span className="font-mono text-[#555]">{id}</span>
        </div>
        <p className="text-[#666] italic animate-pulse">Loading {type} details...</p>
      </div>
    );
  }

  if (effectiveError) {
    return (
      <div className="w-full bg-[#1a1212] border border-red-950/30 rounded-lg p-3 my-1.5 flex flex-col gap-1 text-xs text-red-200">
        <div className="flex items-center justify-between border-b border-red-950/20 pb-1 mb-1">
          <span className="text-[10px] font-bold text-red-400 uppercase tracking-wider">
            {type} reference
          </span>
          <span className="font-mono text-red-400/60">{id}</span>
        </div>
        <p className="text-red-300/80">{effectiveError}</p>
      </div>
    );
  }

  if (!entity) return null;

  if (type === 'task') {
    const statusColors: Record<string, string> = {
      planning: 'bg-zinc-800 border-zinc-700 text-zinc-300',
      ready: 'bg-blue-950/20 border-blue-900/30 text-blue-300',
      in_progress: 'bg-amber-950/20 border-amber-900/30 text-amber-300',
      review_ready: 'bg-purple-950/20 border-purple-900/30 text-purple-300',
      approved: 'bg-emerald-950/20 border-emerald-900/30 text-emerald-300',
      blocked: 'bg-red-950/20 border-red-900/30 text-red-300',
      cancelled: 'bg-zinc-900 border-zinc-800 text-zinc-500',
    };
    return (
      <div 
        onClick={handleClick}
        className="w-full bg-[#1b1b1b]/80 border border-[#2c2c2c] hover:border-[var(--fd-accent-blue)]/50 rounded-lg p-3.5 my-1.5 flex flex-col gap-1 text-xs select-text text-white cursor-pointer hover:bg-[#222]/50 transition-all active:scale-[0.99]"
      >
        <div className="flex items-center justify-between border-b border-[#2c2c2c] pb-2 mb-2">
          <span className="text-[10px] font-bold text-[#888] uppercase tracking-wider flex items-center gap-1.5">
            📋 Task Card
          </span>
          <div className="flex items-center gap-2">
            <span className={`px-2 py-0.5 rounded-full text-[9px] font-bold uppercase border ${statusColors[entity.status] || 'bg-zinc-800 border-zinc-700 text-zinc-300'}`}>
              {entity.status}
            </span>
            <span className="text-[9px] text-[var(--fd-accent-blue)] font-medium hover:underline">Open →</span>
          </div>
        </div>
        <h4 className="font-semibold text-white truncate">{entity.title}</h4>
        {entity.description && (
          <p className="text-[#999] truncate mt-0.5">{entity.description}</p>
        )}
        {entity.assigneeAgentInstanceId && (
          <p className="text-[10px] text-[#777] mt-1">
            Assignee: <span className="text-[#aaa]">{entity.assigneeAgentInstanceId}</span>
          </p>
        )}
      </div>
    );
  }

  if (type === 'chain') {
    const statusColors: Record<string, string> = {
      planning: 'bg-zinc-800 border-zinc-700 text-zinc-300',
      in_progress: 'bg-blue-950/20 border-blue-900/30 text-blue-300',
      reviewing: 'bg-amber-950/20 border-amber-900/30 text-amber-300',
      completed: 'bg-emerald-950/20 border-emerald-900/30 text-emerald-300',
    };
    return (
      <div 
        onClick={handleClick}
        className="w-full bg-[#1b1b1b]/80 border border-[#2c2c2c] hover:border-[var(--fd-accent-blue)]/50 rounded-lg p-3.5 my-1.5 flex flex-col gap-1 text-xs select-text text-white cursor-pointer hover:bg-[#222]/50 transition-all active:scale-[0.99]"
      >
        <div className="flex items-center justify-between border-b border-[#2c2c2c] pb-2 mb-2">
          <span className="text-[10px] font-bold text-[#888] uppercase tracking-wider flex items-center gap-1.5">
            🔗 Chain Card
          </span>
          <div className="flex items-center gap-2">
            <span className={`px-2 py-0.5 rounded-full text-[9px] font-bold uppercase border ${statusColors[entity.status] || 'bg-zinc-800 border-zinc-700 text-zinc-300'}`}>
              {entity.status}
            </span>
            <span className="text-[9px] text-[var(--fd-accent-blue)] font-medium hover:underline">Open →</span>
          </div>
        </div>
        <h4 className="font-semibold text-white truncate">{entity.title}</h4>
        {entity.description && (
          <p className="text-[#999] truncate mt-0.5">{entity.description}</p>
        )}
        {entity.evaluation && entity.evaluation !== 'unreviewed' && (
          <p className="text-[10px] text-[#777] mt-1">
            Evaluation: <span className={`font-semibold ${entity.evaluation === 'good' ? 'text-green-400' : 'text-red-400'}`}>{entity.evaluation}</span>
          </p>
        )}
      </div>
    );
  }

  if (type === 'memory' || type === 'proposal') {
    const statusColors: Record<string, string> = {
      pending: 'bg-amber-950/20 border-amber-900/30 text-amber-300',
      approved: 'bg-emerald-950/20 border-emerald-900/30 text-emerald-300',
      rejected: 'bg-red-950/20 border-red-900/30 text-red-300',
      active: 'bg-blue-950/20 border-blue-900/30 text-blue-300',
      archived: 'bg-zinc-900 border-zinc-800 text-zinc-500',
    };
    return (
      <div 
        onClick={handleClick}
        className="w-full bg-[#1b1b1b]/80 border border-[#2c2c2c] hover:border-[var(--fd-accent-blue)]/50 rounded-lg p-3.5 my-1.5 flex flex-col gap-1 text-xs select-text text-white cursor-pointer hover:bg-[#222]/50 transition-all active:scale-[0.99]"
      >
        <div className="flex items-center justify-between border-b border-[#2c2c2c] pb-2 mb-2">
          <span className="text-[10px] font-bold text-[#888] uppercase tracking-wider flex items-center gap-1.5">
            🧠 Memory Card
          </span>
          <div className="flex items-center gap-2">
            <span className={`px-2 py-0.5 rounded-full text-[9px] font-bold uppercase border ${statusColors[entity.status] || 'bg-zinc-800 border-zinc-700 text-zinc-300'}`}>
              {entity.status}
            </span>
            <span className="text-[9px] text-[var(--fd-accent-blue)] font-medium hover:underline">Open →</span>
          </div>
        </div>
        <h4 className="font-semibold text-white truncate">{entity.title || entity.memoryId || entity.proposalId}</h4>
        <p className="text-[#999] truncate mt-0.5">{entity.body}</p>
        <div className="flex items-center justify-between text-[10px] text-[#777] mt-2 border-t border-[#222] pt-2">
          <span>Target: <span className="text-[#aaa]">{entity.target || 'global'}</span></span>
          <span className="uppercase tracking-wide">{entity.type}</span>
        </div>
      </div>
    );
  }

  return null;
}

function MessageBubble({ message, session }: { message: any; session: any }) {
  console.log('[Render] MessageBubble', message.id);
  const dispatch = useDispatch<any>();
  const [selectedAnswer, setSelectedAnswer] = useState<string | null>(null);

  // Wizard state for multi-question questionnaire
  const [currentQuestionIndex, setCurrentQuestionIndex] = useState(0);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [multiSubmitted, setMultiSubmitted] = useState(false);

  const isUser = message.author === 'user';
  const isInterrupt = !!message.interrupt || (typeof message.body === 'string' && message.body.startsWith('\u001b'));
  const displayBody = (typeof message.body === 'string' && message.body.startsWith('\u001b')) ? message.body.slice(1) : (message.body || '');

  type MultiQuestion = {
    type: 'multi_question';
    questions: Array<{
      id?: string;
      text: string;
      options: string[];
    }>;
  };

  let structuredQuestion: { type: string; question: string; suggested_answers: string[] } | null = null;
  let multiQuestion: MultiQuestion | null = null;
  let smartAnswerBody: string | null = null;

  if (!isUser && message.body) {
    try {
      const parsed = JSON.parse(message.body);
      if (parsed) {
        if (parsed.type === 'multi_question' && Array.isArray(parsed.questions)) {
          multiQuestion = parsed;
        } else if (parsed.type === 'structured_question' && parsed.question && Array.isArray(parsed.suggested_answers)) {
          structuredQuestion = parsed;
        } else if (parsed.type === 'smart_answer' && parsed.body) {
          smartAnswerBody = parsed.body;
        }
      }
    } catch (e) {
      // Fall back to plain markdown
    }
  }

  let textToParse = displayBody;
  if (structuredQuestion) {
    textToParse = structuredQuestion.question;
  } else if (smartAnswerBody) {
    textToParse = smartAnswerBody;
  }
  const refs = parseReferences(textToParse);

  function handleAnswerClick(answer: string) {
    if (selectedAnswer) return;
    setSelectedAnswer(answer);
    const tempId = `local_temp_${Date.now()}`;
    dispatch(sendMessageToSelectedAgent({ body: answer, tempId }));
  }

  function handleMultiSubmit() {
    if (!multiQuestion || multiSubmitted) return;
    setMultiSubmitted(true);

    let summary = '[Answers to Questionnaire]\n';
    multiQuestion.questions.forEach((q, idx) => {
      const ans = answers[idx] ?? '(No answer)';
      summary += `\n${idx + 1}. ${q.text}\n=> ${ans}\n`;
    });

    const tempId = `local_temp_${Date.now()}`;
    dispatch(sendMessageToSelectedAgent({ body: summary, tempId }));
  }

  const isDeliveryFailed = Number(message.deliveryFailedUnixMs || 0) > 0;
  const deliveryLabel = isUser
    ? (message.sending
      ? 'Sending...'
      : message.error
      ? 'Failed'
      : isDeliveryFailed
      ? 'Delivery failed'
      : message.readUnixMs > 0
      ? 'Read'
      : message.deliveredUnixMs > 0
      ? 'Delivered'
      : 'Sent')
    : '';

  const copyText = multiQuestion
    ? 'Questionnaire Card'
    : structuredQuestion
    ? structuredQuestion.question
    : displayBody;

  function renderMultiQuestionCard(mq: MultiQuestion) {
    const currentQ = mq.questions[currentQuestionIndex];
    if (!currentQ) return null;

    const selectedOption = answers[currentQuestionIndex];
    const isLast = currentQuestionIndex === mq.questions.length - 1;
    const hasSelection = selectedOption !== undefined;

    return (
      <div className="w-full bg-[#141414] border border-[#222] rounded-[var(--fd-radius-xl)] p-4 shadow-md animate-fade-in my-2 min-w-[280px]">
        <div className="flex items-center justify-between border-b border-[#222] pb-2.5 mb-3">
          <span className="text-[10px] font-bold text-[var(--fd-accent-blue)] uppercase tracking-wider">
            Questionnaire
          </span>
          <span className="text-[10px] text-[#777] font-mono">
            {multiSubmitted ? 'Completed' : `Question ${currentQuestionIndex + 1} of ${mq.questions.length}`}
          </span>
        </div>

        {multiSubmitted ? (
          <div className="space-y-3 py-1">
            <p className="text-xs text-green-400 font-semibold flex items-center gap-1.5 mb-2">
              <span className="text-sm">✓</span> Questionnaire submitted successfully!
            </p>
            {mq.questions.map((q, idx) => (
              <div key={idx} className="border-l border-[#2c2c2c] pl-3 py-0.5">
                <p className="text-[10px] text-[#666]">{q.text}</p>
                <p className="text-xs text-white font-medium mt-0.5">{answers[idx]}</p>
              </div>
            ))}
          </div>
        ) : (
          <div>
            <p className="text-xs sm:text-sm text-white font-semibold leading-relaxed mb-4">
              {currentQ.text}
            </p>

            <div className="space-y-2">
              {currentQ.options.map((option, idx) => {
                const isSelected = selectedOption === option;
                return (
                  <button
                    key={idx}
                    type="button"
                    onClick={() => setAnswers(prev => ({ ...prev, [currentQuestionIndex]: option }))}
                    className={`w-full text-left text-xs px-4 py-2.5 rounded-lg border transition-colors font-medium ${
                      isSelected
                        ? 'bg-[var(--fd-accent-blue)]/10 text-[var(--fd-accent-blue)] border-[var(--fd-accent-blue)]/40 shadow-sm'
                        : 'bg-[#1b1b1b] text-white border-[#222] hover:bg-[#222] hover:border-[#333]'
                    }`}
                  >
                    {option}
                  </button>
                );
              })}
            </div>

            <div className="flex items-center justify-between border-t border-[#222] pt-3.5 mt-5">
              {currentQuestionIndex > 0 ? (
                <button
                  type="button"
                  onClick={() => setCurrentQuestionIndex(prev => prev - 1)}
                  className="text-xs text-[#999] hover:text-white transition-colors px-3 py-1.5 rounded-md hover:bg-[#222]"
                >
                  Back
                </button>
              ) : (
                <div></div>
              )}

              <div className="flex gap-2">
                {isLast ? (
                  <button
                    type="button"
                    disabled={!hasSelection}
                    onClick={handleMultiSubmit}
                    className={`framer-pill-primary px-4 py-1.5 text-xs font-semibold shadow-sm transition-[transform,colors] duration-200 ${
                      hasSelection ? 'opacity-100 ' : 'opacity-40 cursor-not-allowed'
                    }`}
                  >
                    Submit Answers
                  </button>
                ) : (
                  <button
                    type="button"
                    disabled={!hasSelection}
                    onClick={() => setCurrentQuestionIndex(prev => prev + 1)}
                    className={`framer-pill-primary px-4 py-1.5 text-xs font-semibold shadow-sm transition-[transform,colors] duration-200 ${
                      hasSelection ? 'opacity-100 ' : 'opacity-40 cursor-not-allowed'
                    }`}
                  >
                    Next
                  </button>
                )}
              </div>
            </div>
          </div>
        )}
      </div>
    );
  }

  return (
    <div className={`animate-bubble-pop flex w-full ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`group max-w-[88%] sm:max-w-[86%] md:max-w-[82%] rounded-[var(--fd-radius-xxl)] px-4 py-3 pr-11 transition-[transform,colors] duration-300   border relative overflow-hidden before:content-[''] before:absolute before:top-3 before:w-0 before:h-0 before:border-t-[8px] before:border-t-transparent before:border-b-[8px] before:border-b-transparent ${
          isUser
            ? (message.error
              ? 'border-red-500 bg-red-950/20 text-red-200 before:right-[-12px] before:border-l-[12px] before:border-l-red-950/20'
              : 'border-[var(--fd-accent-blue)]/70 bg-[var(--fd-accent-blue)] text-black before:right-[-12px] before:border-l-[12px] before:border-l-[var(--fd-accent-blue)]')
            : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] text-white before:-left-3 before:border-r-[12px] before:border-r-[var(--fd-surface-1)]'
        } ${message.sending ? 'opacity-60 animate-pulse' : ''}`}
      >
        <ChatHoverCopyButton
          debugId={`message-bubble-copy-btn-${message.id || message.messageId || 'message'}`}
          text={copyText}
          className={`message-copy-button ${isUser ? 'message-copy-button-user' : ''}`}
        />
        {isInterrupt && (
          <div className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-bold uppercase tracking-wider mb-2 border ${
            isUser 
              ? 'bg-black/10 border-black/20 text-black/80' 
              : 'bg-[var(--fd-accent-blue)]/10 border-[var(--fd-accent-blue)]/20 text-[var(--fd-accent-blue)]'
          }`}>
            <span>⚡ Interrupt</span>
          </div>
        )}
        {multiQuestion ? (
          renderMultiQuestionCard(multiQuestion)
        ) : structuredQuestion ? (
          <div>
            <MarkdownContent text={structuredQuestion.question} className={isUser ? 'text-slate-900' : 'text-zinc-200'} />
            <div className="mt-3 flex flex-wrap gap-2 animate-fade-in">
              {structuredQuestion.suggested_answers.map((answer, idx) => {
                const isChosen = selectedAnswer === answer;
                return (
                  <button
                    key={idx}
                    type="button"
                    disabled={selectedAnswer !== null}
                    onClick={() => handleAnswerClick(answer)}
                    className={`text-[11px] sm:text-xs px-3.5 py-1.5 rounded-full transition-[transform,colors] duration-150 font-semibold shadow-sm border ${
                      isChosen
                        ? 'bg-[var(--fd-accent-blue)] text-black border-[var(--fd-accent-blue)] scale-98'
                        : selectedAnswer !== null
                        ? 'bg-[#1a1a1a] text-[#444] border-[#222] cursor-not-allowed opacity-40'
                        : 'bg-[#222] hover:bg-[#2e2e2e] text-white border-[#2e2e2e] hover:border-[var(--fd-accent-blue)]/40 '
                    }`}
                  >
                    {answer}
                  </button>
                );
              })}
            </div>
          </div>
        ) : smartAnswerBody ? (
          <MarkdownContent text={smartAnswerBody} className={isUser ? 'text-slate-900' : 'text-zinc-200'} />
        ) : (
          <MarkdownContent text={displayBody} className={isUser ? 'text-slate-900' : 'text-zinc-200'} />
        )}
        {refs.length > 0 && (
          <div className="mt-3 space-y-2 border-t border-[#222] pt-2.5">
            {refs.map((ref) => (
              <EntityCard key={ref.id} id={ref.id} type={ref.type} session={session} />
            ))}
          </div>
        )}
        <p className={`mt-2 flex items-center justify-end gap-2 text-xs ${isUser ? 'text-slate-900/70' : 'text-[#999]'}`}>
          <span>{message.timestamp}</span>
          {deliveryLabel ? (
            <span
              aria-label={`Message ${deliveryLabel.toLowerCase()}`}
              title={isDeliveryFailed && message.deliveryError ? message.deliveryError : undefined}
              className={isDeliveryFailed ? 'font-semibold text-red-900' : undefined}
            >
              {deliveryLabel}
            </span>
          ) : null}
        </p>
      </div>
    </div>
  );
}
export default memo(MessageBubble);
