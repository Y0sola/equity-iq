import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { DataTable } from "../components/DataTable";
import { SqlCode } from "../components/SqlCode";
import { Async, EmptyState, ErrorState, Loading } from "../components/States";
import { Badge, Card, PageHeader } from "../components/ui";
import { useApi } from "../hooks/useApi";
import { apiGet, type LibraryDetail, type LibraryRun, type LibrarySummary } from "../services/api";

const CATEGORY_ORDER = ["Database", "Data quality", "Equity analysis", "Sector analysis", "Corporate actions", "Reporting"];

export default function SqlLibrary() {
  const { queryId } = useParams();
  const list = useApi<{ count: number; categories: string[]; items: LibrarySummary[] }>("/api/library");
  const navigate = useNavigate();
  const active = queryId ?? list.data?.items[0]?.query_id;

  return (
    <>
      <PageHeader title="SQL Query Library"
        description="Reviewed, read-only queries covering database structure, data quality, equity, sector, corporate-action and reporting questions. Only these allowlisted queries can be run; the API accepts no free-form SQL." />
      <div className="grid gap-5 lg:grid-cols-[18rem_1fr]">
        <Card title="Queries" subtitle={list.data ? `${list.data.count} queries` : undefined} bodyClassName="max-h-[75vh] overflow-y-auto">
          <Async state={list}>
            {(d) => (
              <nav aria-label="Query list" className="py-1">
                {[...d.categories].sort((a, b) => CATEGORY_ORDER.indexOf(a) - CATEGORY_ORDER.indexOf(b)).map((cat) => (
                  <div key={cat} className="mb-2">
                    <p className="px-4 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-wider text-muted">{cat}</p>
                    {d.items.filter((q) => q.category === cat).map((q) => (
                      <Link key={q.query_id} to={`/library/${q.query_id}`}
                        className={`block border-l-2 px-4 py-1.5 text-[13px] ${q.query_id === active ? "border-accent bg-accent-soft font-medium text-accent-strong" : "border-transparent text-ink-2 hover:bg-canvas"}`}>
                        {q.title}
                      </Link>
                    ))}
                  </div>
                ))}
              </nav>
            )}
          </Async>
        </Card>
        {active ? <QueryPanel key={active} queryId={active} onUnknown={() => navigate("/library")} /> : !list.loading && <EmptyState title="No queries available" />}
      </div>
    </>
  );
}

function QueryPanel({ queryId }: { queryId: string; onUnknown: () => void }) {
  const detail = useApi<LibraryDetail>(`/api/library/${encodeURIComponent(queryId)}`);
  const [run, setRun] = useState<{ loading: boolean; error: string | null; result: LibraryRun | null }>({ loading: false, error: null, result: null });

  const execute = async () => {
    setRun({ loading: true, error: null, result: null });
    try {
      setRun({ loading: false, error: null, result: await apiGet<LibraryRun>(`/api/library/${encodeURIComponent(queryId)}/run`) });
    } catch (e) {
      setRun({ loading: false, error: (e as Error).message, result: null });
    }
  };

  return (
    <div className="min-w-0 space-y-5">
      <Async state={detail}>
        {(q) => (
          <Card title={<span className="text-base">{q.title}</span>} subtitle={<span><code>{q.query_id}.sql</code></span>}
            actions={<Badge tone="accent">{q.category}</Badge>}>
            <div className="space-y-4 px-4 py-4">
              <dl className="grid gap-x-4 gap-y-2 text-sm md:grid-cols-[9rem_1fr]">
                <dt className="font-medium text-muted">Business objective</dt><dd>{q.objective}</dd>
                <dt className="font-medium text-muted">Expected output</dt><dd>{q.expected_output}</dd>
                <dt className="font-medium text-muted">Assumptions</dt><dd className="text-ink-2">{q.assumptions}</dd>
                <dt className="font-medium text-muted">SQL concepts</dt>
                <dd className="flex flex-wrap gap-1">{q.concepts.map((c) => <span key={c} className="rounded bg-canvas px-1.5 py-0.5 text-xs text-ink-2 ring-1 ring-line">{c}</span>)}</dd>
              </dl>
              <SqlCode sql={q.sql} label={`${q.query_id}.sql`} />
              {q.view_definitions.length > 0 && (
                <div className="space-y-2">
                  <p className="text-xs font-semibold uppercase tracking-wide text-muted">Views used by this query</p>
                  {q.view_definitions.map((v) => (
                    <details key={v.view} className="rounded-md border border-line">
                      <summary className="cursor-pointer px-3 py-2 text-sm font-medium text-ink-2 hover:bg-canvas"><code>{v.view}</code> definition</summary>
                      <div className="p-2"><SqlCode sql={v.definition} label={v.view} maxHeight="22rem" /></div>
                    </details>
                  ))}
                </div>
              )}
              <div className="flex items-center gap-3">
                <button onClick={execute} disabled={run.loading}
                  className="rounded-md bg-accent px-3.5 py-1.5 text-sm font-semibold text-white hover:bg-accent-strong disabled:opacity-60">
                  {run.loading ? "Running…" : "▶ Run query"}
                </button>
                <span className="text-xs text-muted">Executes in a read-only transaction as the reader role; results capped at 500 rows.</span>
              </div>
            </div>
          </Card>
        )}
      </Async>
      {run.loading && <Card><Loading label="Running query…" /></Card>}
      {run.error && <Card><ErrorState message={run.error} onRetry={execute} /></Card>}
      {run.result && (
        <Card title="Actual output"
          subtitle={`${run.result.row_count} row${run.result.row_count === 1 ? "" : "s"} · ${run.result.elapsed_ms} ms${run.result.truncated ? " · truncated to 500 rows" : ""}`}>
          {run.result.row_count === 0 ? <EmptyState title="The query returned no rows">For checks such as duplicate detection, an empty result means no problems were found.</EmptyState> : (
            <DataTable caption="Query output" rows={run.result.rows} rowKey={(_r, i) => i} maxHeight="60vh"
              columns={run.result.columns.map((c) => ({
                key: c, header: c,
                align: typeof run.result!.rows[0]?.[c] === "number" ? "right" as const : "left" as const,
                value: (r: Record<string, unknown>) => r[c] as string | number | null,
                render: (r: Record<string, unknown>) => renderCell(r[c]),
              }))} />
          )}
        </Card>
      )}
    </div>
  );
}

function renderCell(v: unknown) {
  if (v === null || v === undefined) return <span className="text-muted">NULL</span>;
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") return Number.isInteger(v) ? v.toLocaleString("en-US") : v.toLocaleString("en-US", { maximumFractionDigits: 6 });
  if (Array.isArray(v)) return v.join(", ");
  if (typeof v === "object") return <code className="text-[11px]">{JSON.stringify(v)}</code>;
  return String(v);
}
