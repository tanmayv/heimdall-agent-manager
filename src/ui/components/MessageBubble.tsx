import { useState } from 'react';
import { useDispatch } from 'react-redux';
import { sendMessageToSelectedAgent } from '../store/chatSlice';

function isSafeUrl(url: string) {
  const trimmed = url.trim();
  return /^(https?:|mailto:)/i.test(trimmed) || trimmed.startsWith('/') || trimmed.startsWith('#');
}

function renderInlineMarkdown(text: string, keyPrefix: string) {
  const nodes = [];
  const pattern = /(`[^`]+`|\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)|\*\*([^*]+)\*\*|__([^_]+)__|\*([^*]+)\*|_([^_]+)_)/g;
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
        <a key={key} href={href} target="_blank" rel="noreferrer">
          {renderInlineMarkdown(match[2], `${key}-link`)}
        </a>
      ) : match[2]);
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

function MarkdownContent({ text }: { text: string }) {
  const blocks = [];
  const lines = String(text || '').replace(/\r\n/g, '\n').split('\n');
  let paragraph: string[] = [];
  let listItems: string[] = [];
  let quoteLines: string[] = [];
  let orderedList = false;
  let codeLines: string[] = [];
  let inCode = false;
  let codeLanguage = '';

  function flushParagraph() {
    if (!paragraph.length) return;
    const content = paragraph.join(' ').trim();
    if (content) blocks.push(<p key={`p-${blocks.length}`}>{renderInlineMarkdown(content, `p-${blocks.length}`)}</p>);
    paragraph = [];
  }

  function flushList() {
    if (!listItems.length) return;
    const Tag = orderedList ? 'ol' : 'ul';
    blocks.push(
      <Tag key={`list-${blocks.length}`}>
        {listItems.map((item, index) => <li key={index}>{renderInlineMarkdown(item, `li-${blocks.length}-${index}`)}</li>)}
      </Tag>
    );
    listItems = [];
  }

  function flushQuote() {
    if (!quoteLines.length) return;
    blocks.push(
      <blockquote key={`quote-${blocks.length}`}>
        {quoteLines.map((line, index) => (
          <p key={index}>{renderInlineMarkdown(line, `quote-${blocks.length}-${index}`)}</p>
        ))}
      </blockquote>
    );
    quoteLines = [];
  }

  function flushAllTextBlocks() {
    flushParagraph();
    flushList();
    flushQuote();
  }

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const fence = line.match(/^```\s*([\w-]*)\s*$/);
    if (fence) {
      if (inCode) {
        blocks.push(
          <pre key={`code-${blocks.length}`} data-language={codeLanguage || undefined}>
            <code>{codeLines.join('\n')}</code>
          </pre>
        );
        codeLines = [];
        codeLanguage = '';
        inCode = false;
      } else {
        flushAllTextBlocks();
        inCode = true;
        codeLanguage = fence[1] || '';
      }
      continue;
    }

    if (inCode) {
      codeLines.push(line);
      continue;
    }

    if (!line.trim()) {
      flushAllTextBlocks();
      continue;
    }

    const heading = line.match(/^\s{0,3}(#{1,6})\s+(.+)\s*#*\s*$/);
    if (heading) {
      flushAllTextBlocks();
      const level = Math.min(heading[1].length, 6);
      blocks.push(renderHeading(level, `heading-${blocks.length}`, renderInlineMarkdown(heading[2].trim(), `heading-${blocks.length}`)));
      continue;
    }

    const quote = line.match(/^\s*>\s?(.*)$/);
    if (quote) {
      flushParagraph();
      flushList();
      quoteLines.push(quote[1].trim());
      continue;
    }

    if (looksLikeTableRow(line) && index + 1 < lines.length && isTableSeparator(lines[index + 1])) {
      flushAllTextBlocks();
      const headers = splitTableRow(line);
      const rows: string[][] = [];
      index += 2;
      while (index < lines.length && looksLikeTableRow(lines[index]) && !isTableSeparator(lines[index])) {
        rows.push(splitTableRow(lines[index]));
        index += 1;
      }
      index -= 1;
      blocks.push(
        <div className="markdown-table-wrap" key={`table-${blocks.length}`}>
          <table>
            <thead>
              <tr>{headers.map((cell, cellIndex) => <th key={cellIndex}>{renderInlineMarkdown(cell, `th-${blocks.length}-${cellIndex}`)}</th>)}</tr>
            </thead>
            <tbody>
              {rows.map((row, rowIndex) => (
                <tr key={rowIndex}>
                  {headers.map((_, cellIndex) => (
                    <td key={cellIndex}>{renderInlineMarkdown(row[cellIndex] || '', `td-${blocks.length}-${rowIndex}-${cellIndex}`)}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
      continue;
    }

    const unordered = line.match(/^\s*[-*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (unordered || ordered) {
      flushParagraph();
      flushQuote();
      const nextOrdered = Boolean(ordered);
      if (listItems.length && orderedList !== nextOrdered) flushList();
      orderedList = nextOrdered;
      listItems.push((unordered?.[1] || ordered?.[1] || '').trim());
      continue;
    }

    flushList();
    flushQuote();
    paragraph.push(line.trim());
  }

  if (inCode) {
    blocks.push(
      <pre key={`code-${blocks.length}`} data-language={codeLanguage || undefined}>
        <code>{codeLines.join('\n')}</code>
      </pre>
    );
  }
  flushAllTextBlocks();

  return <div className="markdown-message text-sm leading-6">{blocks}</div>;
}

async function copyMessageText(text: string) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall through to the textarea fallback; Electron/Chromium can expose the
      // Clipboard API while rejecting writes for permission/focus reasons.
    }
  }

  const textarea = document.createElement('textarea');
  try {
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    textarea.style.opacity = '0';
    document.body.appendChild(textarea);
    textarea.select();

    if (!document.execCommand('copy')) {
      throw new Error('Copy command was not accepted');
    }
  } finally {
    textarea.remove();
  }
}

export default function MessageBubble({ message }) {
  const dispatch = useDispatch<any>();
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'error'>('idle');
  const [selectedAnswer, setSelectedAnswer] = useState<string | null>(null);

  const isUser = message.author === 'user';

  let structuredQuestion: { type: string; question: string; suggested_answers: string[] } | null = null;
  if (!isUser && message.body) {
    try {
      const parsed = JSON.parse(message.body);
      if (parsed && parsed.type === 'structured_question' && parsed.question && Array.isArray(parsed.suggested_answers)) {
        structuredQuestion = parsed;
      }
    } catch (e) {
      // Fall back to plain markdown
    }
  }

  function handleAnswerClick(answer: string) {
    if (selectedAnswer) return;
    setSelectedAnswer(answer);
    const tempId = `local_temp_${Date.now()}`;
    dispatch(sendMessageToSelectedAgent({ body: answer, tempId }));
  }

  const deliveryLabel = isUser
    ? (message.sending
      ? 'Sending...'
      : message.error
      ? 'Failed'
      : message.readUnixMs > 0
      ? 'Read'
      : message.deliveredUnixMs > 0
      ? 'Delivered'
      : 'Sent')
    : '';

  async function handleCopy() {
    try {
      const rawText = structuredQuestion ? structuredQuestion.question : (message.body || '');
      await copyMessageText(rawText);
      setCopyState('copied');
    } catch {
      setCopyState('error');
    } finally {
      window.setTimeout(() => setCopyState('idle'), 1800);
    }
  }

  return (
    <div className={`animate-bubble-pop flex w-full ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`group max-w-[88%] sm:max-w-[86%] md:max-w-[82%] rounded-[var(--fd-radius-xxl)] px-4 py-3 pr-11 transition-all duration-300 hover:-translate-y-0.5 hover:scale-[1.01] border relative overflow-hidden before:content-[''] before:absolute before:top-3 before:w-0 before:h-0 before:border-t-[8px] before:border-t-transparent before:border-b-[8px] before:border-b-transparent ${
          isUser
            ? (message.error
              ? 'border-red-500 bg-red-950/20 text-red-200 before:right-[-12px] before:border-l-[12px] before:border-l-red-950/20'
              : 'border-[var(--fd-accent-blue)]/70 bg-[var(--fd-accent-blue)] text-black before:right-[-12px] before:border-l-[12px] before:border-l-[var(--fd-accent-blue)]')
            : 'border-[var(--fd-hairline)] bg-[var(--fd-surface-1)] text-white before:-left-3 before:border-r-[12px] before:border-r-[var(--fd-surface-1)]'
        } ${message.sending ? 'opacity-60 animate-pulse' : ''}`}
      >
        <button
          type="button"
          className={`message-copy-button ${isUser ? 'message-copy-button-user' : ''}`}
          onClick={handleCopy}
          aria-label={copyState === 'copied' ? 'Message copied' : 'Copy message text'}
          title={copyState === 'copied' ? 'Copied' : copyState === 'error' ? 'Copy failed' : 'Copy message'}
        >
          {copyState === 'copied' ? '✓' : copyState === 'error' ? '!' : (
            <svg aria-hidden="true" viewBox="0 0 20 20" fill="none">
              <path d="M7 6.5A2.5 2.5 0 0 1 9.5 4H14a2 2 0 0 1 2 2v7.5a2.5 2.5 0 0 1-2.5 2.5H9a2 2 0 0 1-2-2V6.5Z" stroke="currentColor" strokeWidth="1.5" />
              <path d="M5 13.5H4.5A2.5 2.5 0 0 1 2 11V5.5A2.5 2.5 0 0 1 4.5 3H10" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          )}
        </button>
        {structuredQuestion ? (
          <div>
            <MarkdownContent text={structuredQuestion.question} />
            <div className="mt-3 flex flex-wrap gap-2 animate-fade-in">
              {structuredQuestion.suggested_answers.map((answer, idx) => {
                const isChosen = selectedAnswer === answer;
                return (
                  <button
                    key={idx}
                    type="button"
                    disabled={selectedAnswer !== null}
                    onClick={() => handleAnswerClick(answer)}
                    className={`text-[11px] sm:text-xs px-3.5 py-1.5 rounded-full transition-all font-semibold shadow-sm border ${
                      isChosen
                        ? 'bg-[var(--fd-accent-blue)] text-black border-[var(--fd-accent-blue)] scale-98'
                        : selectedAnswer !== null
                        ? 'bg-[#1a1a1a] text-[#444] border-[#222] cursor-not-allowed opacity-40'
                        : 'bg-[#222] hover:bg-[#2e2e2e] text-white border-[#2e2e2e] hover:border-[var(--fd-accent-blue)]/40 active:scale-95'
                    }`}
                  >
                    {answer}
                  </button>
                );
              })}
            </div>
          </div>
        ) : (
          <MarkdownContent text={message.body} />
        )}
        <p className={`mt-2 flex items-center justify-end gap-2 text-xs ${isUser ? 'text-slate-900/70' : 'text-[#999]'}`}>
          <span>{message.timestamp}</span>
          {deliveryLabel ? <span aria-label={`Message ${deliveryLabel.toLowerCase()}`}>{deliveryLabel}</span> : null}
        </p>
      </div>
    </div>
  );
}
