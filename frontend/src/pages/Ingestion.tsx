import { useState } from "react";
import { DataTable } from "../components/DataTable";
import { Async, EmptyState, ErrorState, Loading } from "../components/States";
import { Card, Field, PageHeader, StatusBadge, inputClass } from "../components/ui";
import { useApi } from "../hooks/useApi";
import { fmtDateTime, fmtInt, fmtNum, fmtPct, titleCase } from "../lib/format";
import { apiGet, type Page } from "../services/api";

interface Flow { stages: { stage: string; detail: string }[]; counts: Record<string, number> }

export default function Ingestion() {
  const flow = useApi<Flow>("/api/lineage/flow");
  const batches = useApi<Page<Record<string, unknown>>>("/api/ingestion/batches");
  return (
    <>
      <PageHeader title="Ingestion & Data Lineage"
        description="How data moves from the provider to the dashboard, every ingestion batch, and record-level lineage from a published price back to the raw provider value." />
      <Card title="Data flow" subtitle="Record counts at each stage (live from the database)" className="mb-5">
        <Async state={flow}>{(f) => <FlowDiagram flow={f} />}</Async>
      </Card>
      <Card title="Ingestion batches" subtitle="One batch per dataset per load. A rerun of an identical snapshot is logged as Skipped (checksum match) and inserts nothing." className="mb-5">
        <Async state={batches}>
          {(d) => (
            <DataTable caption="Ingestion batches" rows={d.items} rowKey={(r) => String(r.ingestion_batch_id)} columns={[
              { key: "id", header: "Batch", align: "right", value: (r) => Number(r.ingestion_batch_id) },
              { key: "t", header: "Dataset", render: (r) => titleCase(String(r.batch_type)) },
              { key: "s", header: "Status", render: (r) => <StatusBadge status={String(r.status)} /> },
              { key: "src", header: "Source", render: (r) => String(r.source) },
              { key: "w", header: "Window", render: (r) => <span className="whitespace-nowrap">{String(r.snapshot_start_date ?? "—")} → {String(r.snapshot_end_date ?? "—")}</span> },
              { key: "st", header: "Started", render: (r) => <span className="whitespace-nowrap">{fmtDateTime(r.start_timestamp as string)}</span> },
              { key: "dur", header: "Load (s)", align: "right", render: (r) => fmtNum(r.load_seconds as number | null, 3) },
              { key: "rcv", header: "Received", align: "right", render: (r) => fmtInt(r.records_received as number) },
              { key: "acc", header: "Accepted", align: "right", render: (r) => fmtInt(r.records_accepted as number) },
              { key: "rej", header: "Rejected", align: "right", render: (r) => fmtInt(r.records_rejected as number) },
              { key: "flg", header: "Flagged", align: "right", render: (r) => fmtInt(r.records_flagged as number) },
              { key: "pr", header: "Pass rate", align: "right", render: (r) => fmtPct(r.record_pass_rate_pct as number | null) },
              { key: "ck", header: "Checksum", render: (r) => <code className="text-[11px] text-muted">{String(r.checksum_prefix ?? "—")}…</code> },
            ]} />
          )}
        </Async>
      </Card>
      <LineageLookup />
    </>
  );
}

function FlowDiagram({ flow }: { flow: Flow }) {
  const c = flow.counts;
  const figures: Record<string, string[]> = {
    "Source": [`${fmtInt(c.batches_loaded)} batches loaded`],
    "Raw staging": [`${fmtInt(c.raw_prices)} prices`, `${fmtInt(c.raw_corporate_actions)} actions`, `${fmtInt(c.raw_company_reference)} companies`],
    "SQL validation": [`${fmtInt(c.active_rules)} rules`, `${fmtInt(c.rule_failures)} record failures`, `${fmtInt(c.issues)} issues`],
    "Validated / quarantine": [`${fmtInt(c.validated_prices)} prices`, `${fmtInt(c.validated_corporate_actions)} actions`, `${fmtInt(c.quarantined_records)} quarantined`],
    "SQL analytics": [`${fmtInt(c.analytics_views)} analytics views`],
    "Dashboard": ["read-only role", "allowlisted queries"],
  };
  return (
    <ol className="flex flex-wrap items-stretch gap-1.5 px-4 py-4" aria-label="Data flow stages">
      {flow.stages.map((s, i) => (
        <li key={s.stage} className="flex items-stretch gap-2">
          <div className="w-[9.25rem] rounded-md border border-line bg-[#f8fafc] px-2.5 py-2.5">
            <p className="text-[10px] font-semibold uppercase tracking-wider text-accent">Step {i + 1}</p>
            <p className="text-sm font-semibold">{s.stage}</p>
            <p className="mt-0.5 text-[11px] leading-snug text-muted">{s.detail}</p>
            <ul className="mt-1.5 space-y-0.5 text-xs font-medium tabular-nums text-ink-2">
              {(figures[s.stage] ?? []).map((x) => <li key={x}>{x}</li>)}
            </ul>
          </div>
          {i < flow.stages.length - 1 && <span aria-hidden className="self-center text-lg text-line-strong">→</span>}
        </li>
      ))}
    </ol>
  );
}

function LineageLookup() {
  const [ticker, setTicker] = useState("NVDA");
  const [date, setDate] = useState("2026-11-23");
  const [state, setState] = useState<{ loading: boolean; error: string | null; data: Record<string, unknown> | null }>({ loading: false, error: null, data: null });
  const valid = /^[A-Z][A-Z.-]{0,9}$/.test(ticker) && /^\d{4}-\d{2}-\d{2}$/.test(date);
  const lookup = async (e?: React.FormEvent) => {
    e?.preventDefault();
    if (!valid) return;
    setState({ loading: true, error: null, data: null });
    try { setState({ loading: false, error: null, data: await apiGet(`/api/lineage/${ticker}/${date}`) }); }
    catch (err) { setState({ loading: false, error: (err as Error).message, data: null }); }
  };
  const d = state.data;
  const rows: [string, string, unknown, unknown][] = d ? [
    ["Open", "open_price", d.open_price, d.raw_open], ["High", "high_price", d.high_price, d.raw_high],
    ["Low", "low_price", d.low_price, d.raw_low], ["Close", "close_price", d.close_price, d.raw_close],
    ["Adjusted close", "adjusted_close", d.adjusted_close, d.raw_adjusted_close], ["Volume", "volume", d.volume, d.raw_volume],
  ] : [];
  return (
    <Card title="Record lineage" subtitle="Trace a validated price back to the exact raw record, batch and provider request.">
      <form onSubmit={lookup} className="flex flex-wrap items-end gap-3 border-b border-line px-4 py-3">
        <Field label="Ticker"><input className={`${inputClass} w-24`} value={ticker} maxLength={10} onChange={(e) => setTicker(e.target.value.toUpperCase())} /></Field>
        <Field label="Trading date"><input type="date" className={inputClass} value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <button type="submit" disabled={!valid || state.loading} className="h-8 rounded-md bg-accent px-3 text-sm font-semibold text-white hover:bg-accent-strong disabled:opacity-50">Trace</button>
      </form>
      {state.loading && <Loading />}
      {state.error && <ErrorState message={state.error} />}
      {!d && !state.loading && !state.error && <EmptyState title="Enter a ticker and trading date, then Trace" />}
      {d && (
        <div className="grid gap-5 px-4 py-4 xl:grid-cols-2">
          <div>
            <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Published value vs raw provider text</p>
            <DataTable caption="Lineage values" rows={rows} rowKey={(r) => r[1]} columns={[
              { key: "f", header: "Field", render: (r) => r[0] },
              { key: "p", header: "core.stock_prices", align: "right", render: (r) => <span className="font-medium">{String(r[2])}</span> },
              { key: "r", header: "staging (as received)", align: "right", render: (r) => <code className="text-[11px]">{String(r[3])}</code> },
            ]} />
            <p className="mt-2 text-xs text-muted">Reported prices are rounded to cents on promotion (the provider's 32-bit float values are exact cents); adjusted close is kept to 6 decimals.</p>
          </div>
          <dl className="grid grid-cols-[9rem_1fr] gap-x-3 gap-y-1.5 text-sm">
            <dt className="text-muted">Price id</dt><dd>{String(d.price_id)}</dd>
            <dt className="text-muted">Raw record id</dt><dd>{String(d.raw_record_id)}</dd>
            <dt className="text-muted">Ingestion batch</dt><dd>{String(d.ingestion_batch_id)}</dd>
            <dt className="text-muted">Source</dt><dd>{String(d.source)}</dd>
            <dt className="text-muted">Snapshot</dt><dd><code className="text-[11px]">{String(d.snapshot_label)}</code></dd>
            <dt className="text-muted">Checksum</dt><dd><code className="break-all text-[11px]">{String(d.source_checksum)}</code></dd>
            <dt className="text-muted">Loaded at</dt><dd>{fmtDateTime(d.ingestion_timestamp as string)}</dd>
            <dt className="text-muted">Request settings</dt>
            <dd><code className="text-[11px]">{JSON.stringify((d.retrieval_parameters as Record<string, unknown>)?.request_parameters ?? {})}</code></dd>
            <dt className="text-muted">Quality issues</dt>
            <dd>{(d.issues as { rule_id: string; status: string }[]).length === 0 ? "none" :
              (d.issues as { rule_id: string; status: string }[]).map((i) => `${i.rule_id} (${i.status.toLowerCase()})`).join(", ")}</dd>
          </dl>
        </div>
      )}
    </Card>
  );
}
