import type { ReactNode } from "react";

export function Loading({ label = "Loading data…" }: { label?: string }) {
  return (
    <div role="status" aria-live="polite" className="flex items-center gap-2 px-4 py-8 text-sm text-muted">
      <span className="h-4 w-4 animate-spin rounded-full border-2 border-line-strong border-t-accent" aria-hidden />
      {label}
    </div>
  );
}

export function ErrorState({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div role="alert" className="m-4 rounded-md border border-neg/30 bg-neg-soft px-4 py-3 text-sm text-neg">
      <p className="font-semibold">Could not load this data</p>
      <p className="mt-1 text-ink-2">{message}</p>
      {onRetry && (
        <button onClick={onRetry} className="mt-2 rounded border border-neg/40 bg-surface px-2.5 py-1 text-xs font-medium text-neg hover:bg-neg-soft">
          Retry
        </button>
      )}
    </div>
  );
}

export function EmptyState({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="px-4 py-8 text-center">
      <p className="text-sm font-medium text-ink-2">{title}</p>
      {children && <div className="mt-1 text-sm text-muted">{children}</div>}
    </div>
  );
}

/** Renders loading / error / content for one useApi() result. */
export function Async<T>({ state, children, empty }: {
  state: { data: T | null; error: string | null; loading: boolean; reload: () => void };
  children: (data: T) => ReactNode;
  empty?: (data: T) => boolean;
}) {
  if (state.loading && !state.data) return <Loading />;
  if (state.error) return <ErrorState message={state.error} onRetry={state.reload} />;
  if (!state.data) return <EmptyState title="No data" />;
  if (empty && empty(state.data)) return <EmptyState title="No records match" />;
  return <>{children(state.data)}</>;
}
