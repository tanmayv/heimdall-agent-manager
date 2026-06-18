export default function MessageBubble({ message }) {
  const isUser = message.author === 'user';
  const hasReadReceipt = isUser && message.readUnixMs && message.readUnixMs > 0;

  return (
    <div className={`animate-bubble-pop flex w-full ${isUser ? 'justify-end' : 'justify-start'}`}>
      <div
        className={`max-w-[88%] sm:max-w-[86%] md:max-w-[82%] rounded-[1.75rem] px-4 py-3 shadow-lg transition-all duration-300 hover:-translate-y-0.5 hover:scale-[1.01] ${
          isUser
            ? 'rounded-br-lg bg-gradient-to-br from-blue-500 to-blue-600 text-white shadow-blue-950/30'
            : 'rounded-bl-lg border border-slate-800 bg-slate-900 text-slate-100 shadow-slate-950/30 hover:border-slate-700'
        }`}
      >
        <p className="text-sm leading-6">{message.body}</p>
        <div className="mt-2 flex items-center justify-end gap-2 text-xs">
          <p className={isUser ? 'text-blue-100' : 'text-slate-500'}>{message.timestamp}</p>
          {isUser && hasReadReceipt ? <p className="font-medium text-blue-200/85">Read {message.readAt}</p> : null}
        </div>
      </div>
    </div>
  );
}
