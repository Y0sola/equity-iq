import { useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { DataTable } from "../components/DataTable";
import { Async, EmptyState } from "../components/States";
import {
  Badge, Card, Field, IssueClassBadge, OutcomeBadge, PageHeader, SeverityBadge, StatusBadge, SyntheticBanner, Tabs, inputClass,
} from "../components/ui";
import { useApi } from "../hooks/useApi";
import { fmtDate, fmtDateTime, fmtInt, fmtPct, titleCase } from "../lib/format";
import type { DimensionScore, IssueRow, Page, QualitySummary, RuleResult } from "../services/api";

type Tab = "summary" | "issues" | "rules" | "quarantine" | "synthetic";

export default function DataQuality() {
  const [params, setParams] = useSearchParams();
  const tab = (params.get("tab") as Tab) || "summary";
  const setTab = (t: Tab) => setParams((p) => { p.set("tab", t); p.delete("issue"); return p; });
  return (
    <>
      <PageHeader title="Data Quality"
        description="37 SQL rules validate every raw record before promotion. Confirmed defects are quarantined; reviewable anomalies are published but flagged for an analyst. Record counts and issue counts are reported separately." />
      <div className="mb-4">
        <Tabs value={tab} onChange={setTab} options={[
          { value: "summary", label: "Scores & summary" }, { value: "issues", label: "Issues" },
          { value: "rules", label: "Rule catalogue" }, { value: "quarantine", label: "Quarantine" },
          { value: "synthetic", label: "Synthetic tests" },
        ]} />
      </div>
      {tab === "summary" && <SummaryTab />}
      {tab === "issues" && <IssuesTab />}
      {tab === "rules" && <RulesTab />}
      {tab === "quarantine" && <QuarantineTab />}
      {tab === "synthetic" && <SyntheticTab />}
    </>
  );
}

// ------------------------------------------------------------------ summary
function ScoreCard({ d }: { d: DimensionScore }) {
  const pct = d.score_pct;
  const tone = pct === null ? "info" : pct >= 99.5 ? "pos" : pct >= 95 ? "warn" : "neg";
  return (
    <div className="rounded-lg border border-line bg-surface p-4">
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-muted">{titleCase(d.dimension)}</p>
          <p className="text-[11px] text-muted">scope: {d.scope}</p>
        </div>
        <Badge tone={tone} icon={tone === "pos" ? "✓" : tone === "info" ? "–" : "▲"}>{pct === null ? "N/A" : tone === "pos" ? "Pass" : "Below target"}</Badge>
      </div>
      <p className="mt-2 text-2xl font-semibold tabular-nums">{pct === null ? "N/A" : fmtPct(pct)}</p>
      <p className="text-xs tabular-nums text-ink-2">{fmtInt(d.numerator)} / {fmtInt(d.denominator)}</p>
      <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-canvas" aria-hidden>
        <div className="h-full bg-accent" style={{ width: `${pct ?? 0}%` }} />
      </div>
      <p className="mt-2 text-[11px] leading-snug text-muted">{d.definition}</p>
    </div>
  );
}

function SummaryTab() {
  const state = useApi<QualitySummary>("/api/quality/summary");
  return (
    <Async state={state}>
      {(d) => {
        const s = d.snapshot as Record<string, number>;
        return (
          <div className="space-y-5">
            <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
              {d.dimension_scores.map((x) => <ScoreCard key={`${x.dimension}-${x.scope}`} d={x} />)}
            </div>
            <p className="text-xs text-muted">
              Scores cover the latest validated price batch. Dimensions have different scopes and are deliberately <strong>not averaged</strong> into one number;
              reviewable anomalies are excluded because an unusual-but-genuine move is not an error.
            </p>
            <div className="grid gap-5 xl:grid-cols-2">
              <Card title="Records vs issues" subtitle="Production snapshot">
                <dl className="grid grid-cols-2 gap-x-6 gap-y-2 px-4 py-3 text-sm">
                  {[
                    ["Raw price records (all batches)", s.raw_price_records_all_batches],
                    ["Validated price records", s.validated_price_records],
                    ["Expected (universe × sessions)", s.expected_price_records],
                    ["Quarantined records", s.quarantined_records],
                    ["Open confirmed-defect issues", s.open_confirmed_defect_issues],
                    ["Open anomaly issues", s.open_anomaly_issues],
                  ].map(([label, v]) => (
                    <div key={String(label)} className="flex justify-between border-b border-line py-1">
                      <dt className="text-ink-2">{label}</dt><dd className="font-semibold tabular-nums">{fmtInt(Number(v))}</dd>
                    </div>
                  ))}
                </dl>
              </Card>
              <Card title="Issues by class, severity and status" subtitle="Counts of issues (one issue can cover several records)">
                {d.issues_by_class_severity_status.length === 0 ? <EmptyState title="No issues recorded" /> : (
                  <DataTable caption="Issue summary" rowKey={(r) => `${r.issue_class}-${r.severity}-${r.status}`} rows={d.issues_by_class_severity_status} columns={[
                    { key: "c", header: "Class", render: (r) => <IssueClassBadge issueClass={r.issue_class} /> },
                    { key: "s", header: "Severity", render: (r) => <SeverityBadge severity={r.severity} /> },
                    { key: "st", header: "Status", render: (r) => <StatusBadge status={r.status} /> },
                    { key: "n", header: "Issues", align: "right", value: (r) => r.issues },
                    { key: "t", header: "Tickers", align: "right", value: (r) => r.tickers_affected },
                  ]} />
                )}
              </Card>
            </div>
            <div className="grid gap-5 xl:grid-cols-2">
              <Card title="Field completeness" subtitle="Present and parseable ÷ evaluated (latest price batch)">
                <DataTable caption="Field completeness" rowKey={(r) => r.field_name} rows={d.field_completeness} columns={[
                  { key: "f", header: "Field", value: (r) => r.field_name, render: (r) => <code className="text-xs">{r.field_name}</code> },
                  { key: "e", header: "Evaluated", align: "right", value: (r) => r.records_evaluated, render: (r) => fmtInt(r.records_evaluated) },
                  { key: "p", header: "Present", align: "right", value: (r) => r.present, render: (r) => fmtInt(r.present) },
                  { key: "v", header: "Parseable", align: "right", value: (r) => r.present_and_parseable, render: (r) => fmtInt(r.present_and_parseable) },
                  { key: "c", header: "Completeness", align: "right", value: (r) => r.completeness_pct, render: (r) => fmtPct(r.completeness_pct) },
                ]} />
              </Card>
              <Card title="Batch outcomes" subtitle="Per ingestion batch: what was received and what happened to it">
                <DataTable caption="Batch outcomes" rowKey={(r) => String(r.ingestion_batch_id)} rows={d.batches} columns={[
                  { key: "b", header: "Batch", value: (r) => Number(r.ingestion_batch_id), align: "right" },
                  { key: "t", header: "Type", render: (r) => titleCase(String(r.batch_type)) },
                  { key: "r", header: "Received", align: "right", render: (r) => fmtInt(Number(r.records_received)) },
                  { key: "c", header: "Clean", align: "right", render: (r) => fmtInt(Number(r.clean)) },
                  { key: "f", header: "Flagged", align: "right", render: (r) => fmtInt(Number(r.accepted_with_flags)) },
                  { key: "q", header: "Quarantined", align: "right", render: (r) => fmtInt(Number(r.quarantined)) },
                  { key: "p", header: "Pass rate", align: "right", render: (r) => fmtPct(r.record_pass_rate_pct as number | null) },
                ]} />
              </Card>
            </div>
          </div>
        );
      }}
    </Async>
  );
}

// ------------------------------------------------------------------ issues
const PAGE_SIZE = 50;

function IssuesTab() {
  const [params, setParams] = useSearchParams();
  const [filters, setFilters] = useState({
    ticker: "", rule_id: "", severity: "", status: "", issue_class: "", category: "", date_from: "", date_to: "",
  });
  const [offset, setOffset] = useState(0);
  const rules = useApi<Page<RuleResult>>("/api/quality/rules");
  const tickerValid = filters.ticker === "" || /^[A-Z][A-Z.-]{0,9}$/.test(filters.ticker);
  const state = useApi<Page<IssueRow>>(tickerValid ? "/api/quality/issues" : null,
    { ...filters, limit: PAGE_SIZE, offset });
  const selected = params.get("issue");
  const set = (k: keyof typeof filters) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    setOffset(0); setFilters((f) => ({ ...f, [k]: k === "ticker" ? e.target.value.toUpperCase() : e.target.value }));
  };
  const select = (k: keyof typeof filters, options: [string, string][]) => (
    <select className={inputClass} value={filters[k]} onChange={set(k)}>
      <option value="">All</option>
      {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
    </select>
  );

  return (
    <Card title="Issue register" subtitle="Filter by security, rule, severity, status, class, dimension and date. Click a row for the full explanation.">
      <div className="flex flex-wrap items-end gap-3 border-b border-line px-4 py-3">
        <Field label="Ticker">
          <input className={`${inputClass} w-24 ${tickerValid ? "" : "border-neg"}`} value={filters.ticker} onChange={set("ticker")}
            placeholder="e.g. NVDA" aria-invalid={!tickerValid} maxLength={10} />
        </Field>
        <Field label="Rule">{select("rule_id", (rules.data?.items ?? []).map((r) => [r.rule_id, `${r.rule_id} ${r.rule_name}`]))}</Field>
        <Field label="Severity">{select("severity", [["CRITICAL", "Critical"], ["WARNING", "Warning"], ["INFO", "Info"]])}</Field>
        <Field label="Status">{select("status", [["OPEN", "Open"], ["UNDER_REVIEW", "Under review"], ["RESOLVED", "Resolved"], ["DISMISSED", "Dismissed"]])}</Field>
        <Field label="Class">{select("issue_class", [["CONFIRMED_DEFECT", "Confirmed defect"], ["REVIEWABLE_ANOMALY", "Reviewable anomaly"]])}</Field>
        <Field label="Dimension">{select("category", ["COMPLETENESS", "UNIQUENESS", "VALIDITY", "CONSISTENCY", "TIMELINESS", "ANOMALY"].map((c) => [c, titleCase(c)]))}</Field>
        <Field label="From"><input type="date" className={inputClass} value={filters.date_from} onChange={set("date_from")} /></Field>
        <Field label="To"><input type="date" className={inputClass} value={filters.date_to} onChange={set("date_to")} /></Field>
        <button className="h-8 rounded-md px-2 text-xs font-medium text-accent hover:underline"
          onClick={() => { setOffset(0); setFilters({ ticker: "", rule_id: "", severity: "", status: "", issue_class: "", category: "", date_from: "", date_to: "" }); }}>
          Clear filters
        </button>
      </div>
      {!tickerValid && <p className="px-4 pt-2 text-xs text-neg">Ticker must be upper-case letters, e.g. AAPL.</p>}
      <Async state={state} empty={(d) => d.items.length === 0}>
        {(d) => (
          <>
            <DataTable<IssueRow> caption="Issues" rows={d.items} rowKey={(r) => r.issue_id} maxHeight="60vh"
              onRowClick={(r) => setParams((p) => { p.set("issue", String(r.issue_id)); return p; })} columns={[
                { key: "ticker", header: "Ticker", value: (r) => r.ticker, render: (r) => <span className="font-semibold">{r.ticker ?? "—"}</span> },
                { key: "date", header: "Date", value: (r) => r.trade_date, render: (r) => fmtDate(r.trade_date) },
                { key: "rule", header: "Rule", value: (r) => r.rule_id, render: (r) => <span><code className="text-[11px] text-muted">{r.rule_id}</code> {r.rule_name}</span> },
                { key: "field", header: "Field", render: (r) => <code className="text-[11px]">{r.affected_field}</code> },
                { key: "obs", header: "Observed value", render: (r) => <span className="text-ink-2">{r.observed_value}</span> },
                { key: "exp", header: "Expected condition", render: (r) => <span className="text-muted">{r.expected_condition}</span> },
                { key: "sev", header: "Severity", value: (r) => r.severity, render: (r) => <SeverityBadge severity={r.severity} /> },
                { key: "cls", header: "Class", render: (r) => <IssueClassBadge issueClass={r.issue_class} /> },
                { key: "st", header: "Status", value: (r) => r.status, render: (r) => <StatusBadge status={r.status} /> },
                { key: "det", header: "Detected", value: (r) => r.detected_at, render: (r) => <span className="whitespace-nowrap text-muted">{fmtDateTime(r.detected_at)}</span> },
              ]} />
            <div className="flex items-center justify-between border-t border-line px-4 py-2 text-xs text-ink-2">
              <span>{d.total === 0 ? "No issues" : `Showing ${offset + 1}–${offset + d.count} of ${fmtInt(d.total ?? d.count)} issues`}</span>
              <div className="flex gap-2">
                <button disabled={offset === 0} onClick={() => setOffset((o) => Math.max(0, o - PAGE_SIZE))}
                  className="rounded border border-line-strong px-2 py-1 disabled:opacity-40">← Previous</button>
                <button disabled={offset + d.count >= (d.total ?? 0)} onClick={() => setOffset((o) => o + PAGE_SIZE)}
                  className="rounded border border-line-strong px-2 py-1 disabled:opacity-40">Next →</button>
              </div>
            </div>
          </>
        )}
      </Async>
      {selected && <IssueDrawer issueId={selected} onClose={() => setParams((p) => { p.delete("issue"); return p; })} />}
    </Card>
  );
}

interface IssueDetail {
  issue: IssueRow & { rule_description: string; business_justification: string; resolution_notes: string | null; last_detected_batch_id: number; ingestion_batch_id: number };
  proposed_handling: string;
  affected_records: { failure_id: number; record_kind: string; raw_id: number; ingestion_batch_id: number; affected_field: string; observed_value: string; outcome: string; failed_rules: string[] }[];
}

function IssueDrawer({ issueId, onClose }: { issueId: string; onClose: () => void }) {
  const state = useApi<IssueDetail>(`/api/quality/issues/${encodeURIComponent(issueId)}`);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    ref.current?.focus();
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="fixed inset-0 z-40 flex justify-end bg-[#0f1e36]/25" onClick={onClose}>
      <div ref={ref} tabIndex={-1} role="dialog" aria-modal="true" aria-label="Issue detail"
        className="h-full w-full max-w-xl overflow-y-auto bg-surface shadow-xl outline-none" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between border-b border-line px-5 py-3">
          <h2 className="text-sm font-semibold">Issue #{issueId}</h2>
          <button onClick={onClose} className="rounded px-2 py-1 text-sm text-muted hover:bg-canvas" aria-label="Close issue detail">✕</button>
        </div>
        <Async state={state}>
          {({ issue: i, proposed_handling, affected_records }) => (
            <div className="space-y-4 px-5 py-4 text-sm">
              <div className="flex flex-wrap gap-2">
                <SeverityBadge severity={i.severity} /><IssueClassBadge issueClass={i.issue_class} /><StatusBadge status={i.status} />
              </div>
              <div>
                <p className="text-xs text-muted"><code>{i.rule_id}</code> · {titleCase(i.rule_category ?? "")}</p>
                <p className="text-base font-semibold">{i.rule_name}</p>
                <p className="mt-1 text-ink-2">{i.ticker ?? "—"} · {fmtDate(i.trade_date)} · field <code>{i.affected_field}</code></p>
              </div>
              <dl className="grid grid-cols-[9rem_1fr] gap-x-3 gap-y-2">
                <dt className="text-muted">Observed</dt><dd className="font-medium">{i.observed_value}</dd>
                <dt className="text-muted">Expected</dt><dd>{i.expected_condition}</dd>
                <dt className="text-muted">Detected</dt><dd>{fmtDateTime(i.detected_at)} (seen {i.detection_count}×)</dd>
                <dt className="text-muted">Batches</dt><dd>first {i.ingestion_batch_id}, last {i.last_detected_batch_id}</dd>
              </dl>
              <section><h3 className="text-xs font-semibold uppercase tracking-wide text-muted">What the rule checks</h3><p className="mt-1">{i.rule_description}</p></section>
              <section><h3 className="text-xs font-semibold uppercase tracking-wide text-muted">Why it matters</h3><p className="mt-1">{i.business_justification}</p></section>
              <section><h3 className="text-xs font-semibold uppercase tracking-wide text-muted">Handling</h3><p className="mt-1">{proposed_handling}</p></section>
              {i.resolution_notes && <section><h3 className="text-xs font-semibold uppercase tracking-wide text-muted">Notes</h3><p className="mt-1">{i.resolution_notes}</p></section>}
              <section>
                <h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Affected raw records ({affected_records.length})</h3>
                {affected_records.length === 0 ? <p className="text-muted">No raw record: this issue is about a record that was never received.</p> : (
                  <DataTable caption="Affected records" rowKey={(r) => r.failure_id} rows={affected_records} columns={[
                    { key: "k", header: "Kind", render: (r) => titleCase(r.record_kind) },
                    { key: "id", header: "Raw id", align: "right", value: (r) => r.raw_id },
                    { key: "b", header: "Batch", align: "right", value: (r) => r.ingestion_batch_id },
                    { key: "o", header: "Outcome", render: (r) => <OutcomeBadge outcome={r.outcome} /> },
                    { key: "r", header: "All failed rules", render: (r) => <span className="text-[11px]">{r.failed_rules?.join(", ")}</span> },
                  ]} />
                )}
              </section>
            </div>
          )}
        </Async>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ rules
function RulesTab() {
  const state = useApi<Page<RuleResult>>("/api/quality/rules");
  return (
    <Card title="Rule catalogue" subtitle="Failing records (distinct raw records) and issues (distinct problems) are counted separately.">
      <Async state={state}>
        {(d) => (
          <DataTable<RuleResult> caption="Rule catalogue" rows={d.items} rowKey={(r) => r.rule_id} maxHeight="70vh" columns={[
            { key: "id", header: "Rule", value: (r) => r.rule_id, render: (r) => <code className="text-[11px]">{r.rule_id}</code> },
            { key: "name", header: "Name & justification", value: (r) => r.rule_name, render: (r) => (
              <div className="max-w-md"><p className="font-medium">{r.rule_name}</p><p className="text-xs text-muted">{r.business_justification}</p></div>) },
            { key: "cat", header: "Dimension", value: (r) => r.rule_category, render: (r) => titleCase(r.rule_category) },
            { key: "sev", header: "Severity", value: (r) => r.severity, render: (r) => <SeverityBadge severity={r.severity} /> },
            { key: "cls", header: "Class", render: (r) => <IssueClassBadge issueClass={r.issue_class} /> },
            { key: "h", header: "Handling", value: (r) => r.handling, render: (r) => titleCase(r.handling) },
            { key: "exp", header: "Expected condition", render: (r) => <code className="text-[11px] text-ink-2">{r.expected_condition}</code> },
            { key: "fr", header: "Failing records", align: "right", value: (r) => r.failing_records },
            { key: "is", header: "Issues", align: "right", value: (r) => r.issues_total },
            { key: "un", header: "Unresolved", align: "right", value: (r) => r.issues_unresolved },
          ]} />
        )}
      </Async>
    </Card>
  );
}

// ------------------------------------------------------------------ quarantine
function QuarantineTab() {
  const state = useApi<Page<Record<string, unknown>>>("/api/quality/quarantine", { limit: 500 });
  return (
    <Card title="Quarantined records" subtitle="Raw records with a critical (QUARANTINE) failure. They stay in staging for investigation and are never promoted.">
      <Async state={state}>
        {(d) => d.items.length === 0 ? (
          <EmptyState title="No quarantined records">The current real snapshot passed every critical rule. The Synthetic tests tab shows quarantine working on seeded defects.</EmptyState>
        ) : (
          <DataTable caption="Quarantined records" rows={d.items} rowKey={(r) => `${r.record_kind}-${r.raw_id}`} maxHeight="65vh" columns={[
            { key: "k", header: "Kind", render: (r) => titleCase(String(r.record_kind)) },
            { key: "id", header: "Raw id", align: "right", value: (r) => Number(r.raw_id) },
            { key: "t", header: "Ticker", render: (r) => String(r.ticker ?? "—") },
            { key: "d", header: "Date", render: (r) => String(r.record_date ?? "—") },
            { key: "r", header: "Failed rules", render: (r) => (r.failed_rules as string[]).join(", ") },
            { key: "v", header: "Raw values as received", render: (r) => <code className="text-[11px]">{String(r.raw_values)}</code> },
          ]} />
        )}
      </Async>
    </Card>
  );
}

// ------------------------------------------------------------------ synthetic
interface Synthetic {
  dataset: string; generated_at: string; command: string; totals: { tests: number; passed: number; failed: number };
  sections: { section: string; tests: number; passed: number }[];
  tests: { no: number; section: string; test: string; expected: string; actual: string; passed: boolean }[];
  fixtures: { fixture_id: string; dataset: string; ticker: string; record_key: string | null; expected_rules: string[]; expected_outcome: string; description: string }[];
}

function SyntheticTab() {
  const state = useApi<Synthetic>("/api/quality/synthetic-tests");
  return (
    <>
      <SyntheticBanner />
      <Async state={state}>
        {(d) => (
          <div className="space-y-5">
            <div className="grid gap-3 sm:grid-cols-3">
              <div className="rounded-lg border border-line bg-surface p-4"><p className="text-xs uppercase text-muted">Tests run</p><p className="text-2xl font-semibold">{d.totals.tests}</p></div>
              <div className="rounded-lg border border-line bg-surface p-4"><p className="text-xs uppercase text-muted">Passed</p><p className="text-2xl font-semibold text-pos">✓ {d.totals.passed}</p></div>
              <div className="rounded-lg border border-line bg-surface p-4"><p className="text-xs uppercase text-muted">Failed</p><p className={`text-2xl font-semibold ${d.totals.failed ? "text-neg" : ""}`}>{d.totals.failed}</p></div>
            </div>
            <p className="text-xs text-muted">Generated {fmtDateTime(d.generated_at)} by <code>{d.command}</code>. Expected outcomes were written before the framework ran.</p>
            <Card title="Seeded fixtures and expected outcomes">
              <DataTable caption="Fixtures" rows={d.fixtures} rowKey={(r) => r.fixture_id} maxHeight="45vh" columns={[
                { key: "id", header: "Fixture", value: (r) => r.fixture_id },
                { key: "desc", header: "Description", value: (r) => r.description },
                { key: "t", header: "Ticker", render: (r) => r.ticker || "(blank)" },
                { key: "k", header: "Record", render: (r) => r.record_key ?? "—" },
                { key: "r", header: "Expected rules", render: (r) => r.expected_rules.length ? <code className="text-[11px]">{r.expected_rules.join(", ")}</code> : <span className="text-muted">none</span> },
                { key: "o", header: "Expected outcome", render: (r) => titleCase(r.expected_outcome) },
              ]} />
            </Card>
            <Card title="Test results" subtitle={d.sections.map((s) => `${s.section}: ${s.passed}/${s.tests}`).join(" · ")}>
              <DataTable caption="Test results" rows={d.tests} rowKey={(r) => r.no} maxHeight="55vh" columns={[
                { key: "n", header: "#", align: "right", value: (r) => r.no },
                { key: "s", header: "Section", value: (r) => r.section },
                { key: "t", header: "Test", value: (r) => r.test },
                { key: "e", header: "Expected", render: (r) => <code className="text-[11px]">{r.expected}</code> },
                { key: "a", header: "Actual", render: (r) => <code className="text-[11px]">{r.actual}</code> },
                { key: "p", header: "Result", render: (r) => r.passed ? <Badge tone="pos" icon="✓">Pass</Badge> : <Badge tone="neg" icon="✖">Fail</Badge> },
              ]} />
            </Card>
          </div>
        )}
      </Async>
    </>
  );
}
