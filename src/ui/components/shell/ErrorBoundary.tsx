import React from 'react';

type ErrorBoundaryProps = {
  children: React.ReactNode;
  /** Remounts the boundary (clears the error) when this value changes. */
  resetKey?: string | number;
  /** Optional label for the surface that failed, shown in the fallback. */
  label?: string;
};

type ErrorBoundaryState = {
  error: Error | null;
};

/**
 * Catches render/lifecycle exceptions in its subtree and shows an inline
 * fallback instead of letting the whole React root unmount to a blank page.
 * Without a boundary, one bad piece of data (e.g. an object rendered as a React
 * child) takes down the entire app.
 */
export default class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    // Surface to the console for diagnosis; never rethrow.
    // eslint-disable-next-line no-console
    console.error('[ErrorBoundary] caught render error', error, info?.componentStack);
  }

  componentDidUpdate(prev: ErrorBoundaryProps) {
    if (this.state.error && prev.resetKey !== this.props.resetKey) {
      this.setState({ error: null });
    }
  }

  private handleReset = () => this.setState({ error: null });

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;

    const where = this.props.label ? ` in ${this.props.label}` : '';
    return (
      <div
        data-debug-id="error-boundary-fallback"
        className="m-4 rounded-2xl border border-red-500/30 bg-red-950/20 p-6 text-sm text-red-100"
        role="alert"
      >
        <h2 className="mb-1 text-base font-bold text-red-200">Something went wrong{where}.</h2>
        <p className="mb-3 text-red-200/80">
          This section hit an unexpected error and was contained so the rest of the app keeps working.
        </p>
        {error?.message ? (
          <pre className="mb-3 max-h-40 overflow-auto whitespace-pre-wrap rounded-lg bg-black/40 p-3 font-mono text-[11px] text-red-200/90">
            {error.message}
          </pre>
        ) : null}
        <div className="flex gap-2">
          <button
            type="button"
            data-debug-id="error-boundary-retry"
            onClick={this.handleReset}
            className="rounded-xl bg-white/10 px-4 py-2 text-sm font-semibold text-white hover:bg-white/15"
          >
            Try again
          </button>
          <button
            type="button"
            data-debug-id="error-boundary-reload"
            onClick={() => window.location.reload()}
            className="rounded-xl bg-white/5 px-4 py-2 text-sm font-semibold text-zinc-300 hover:bg-white/10"
          >
            Reload page
          </button>
        </div>
      </div>
    );
  }
}
